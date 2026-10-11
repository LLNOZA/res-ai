import AVFAudio
import Foundation

/// Converts each mic tap buffer to the target format on the audio thread.
/// Mismatched PCM formats (typically Float32 48 kHz → Int16 16 kHz) yield no transcripts.
final class SpeechTapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private var pendingInput: AVAudioPCMBuffer?

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        converter.primeMethod = .none
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFormat = converter.outputFormat
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * max(ratio, 1)).rounded(.up))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1))
        else {
            return nil
        }

        pendingInput = buffer
        defer { pendingInput = nil }

        var nsError: NSError?
        let status = converter.convert(to: output, error: &nsError) { [self] _, statusPtr in
            if let input = pendingInput {
                pendingInput = nil
                statusPtr.pointee = .haveData
                return input
            }
            statusPtr.pointee = .noDataNow
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Forwards mapped 0…1 levels off the audio thread without capturing the MainActor engine.
final class AudioLevelBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent: TimeInterval?
    private var publishHandler: ((Float) -> Void)?

    var publish: ((Float) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return publishHandler
        }
        set {
            lock.lock()
            publishHandler = newValue
            lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        lastSent = nil
        lock.unlock()
    }

    func ingest(mappedLevel: Float, now: TimeInterval) {
        lock.lock()
        let allowed = AudioLevelSmoother.shouldPublish(lastSent: lastSent, now: now)
        let handler = allowed ? publishHandler : nil
        if allowed {
            lastSent = now
        }
        lock.unlock()
        guard allowed else { return }
        Task { @MainActor in
            handler?(mappedLevel)
        }
    }
}

/// Whether the input node's formats can be tapped. `installTap` with a format whose
/// sample rate differs from the hardware, or with 0 Hz / 0 channels, raises an
/// Objective-C exception that ends the process, so every such case becomes an error.
enum MicrophoneFormatCheck: Equatable, Sendable {
    case ok
    /// No usable input (no device, Bluetooth profile switching, 0 Hz, 0 channels).
    case unavailable
    /// The node still reports the previous device's format.
    case mismatch

    static func check(
        hardwareSampleRate: Double,
        hardwareChannels: UInt32,
        tapSampleRate: Double,
        tapChannels: UInt32
    ) -> MicrophoneFormatCheck {
        guard hardwareSampleRate > 0, hardwareChannels > 0,
              tapSampleRate > 0, tapChannels > 0 else {
            return .unavailable
        }
        return hardwareSampleRate == tapSampleRate ? .ok : .mismatch
    }
}

/// The microphone side of a dictation engine, replaceable in tests.
@MainActor
protocol AudioCapturing: AnyObject {
    var audioLevelBridge: AudioLevelBridge { get }
    /// Called when capture stopped by itself (input device changed and could not be resumed).
    var onInterrupted: ((Error) -> Void)? { get set }
    func start(outputFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Shared microphone tap used by SpeechAnalyzer and SFSpeechRecognizer engines.
/// The tap block runs on the audio render queue and must not capture MainActor state.
@MainActor
final class MicrophoneCapture: AudioCapturing {
    private var audioEngine = AVAudioEngine()
    private var tapInstalled = false
    /// Set after `AVAudioEngineConfigurationChange`: the engine keeps the old device's
    /// format, so the next start builds a fresh engine.
    private var needsNewEngine = false
    private var configurationObserver: NSObjectProtocol?
    private var activeOutputFormat: AVAudioFormat?
    private var activeOnBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var configurationRestarts = 0
    let audioLevelBridge = AudioLevelBridge()
    var onInterrupted: ((Error) -> Void)?

    private static let maxConfigurationRestarts = 3

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        configurationRestarts = 0
        try startEngine(outputFormat: outputFormat, onBuffer: onBuffer)
    }

    private func startEngine(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        // A second tap on bus 0 raises an exception, so a double start restarts instead.
        if tapInstalled || audioEngine.isRunning {
            stop()
        }
        if needsNewEngine {
            replaceEngine()
        }

        audioEngine.prepare()
        if formatCheck() == .mismatch {
            replaceEngine()
            audioEngine.prepare()
        }
        switch formatCheck() {
        case .ok:
            break
        case .unavailable:
            throw SpeechDictationError.audioEngineFailed("マイク入力が見つかりません。入力装置を確認してください。")
        case .mismatch:
            needsNewEngine = true
            throw SpeechDictationError.audioDeviceChanged
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = SpeechTapConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechDictationError.audioEngineFailed("Could not convert microphone audio to the analyzer format.")
        }

        // The tap block runs on the audio render queue. It must not inherit MainActor isolation
        // from this method, otherwise Swift's runtime isolation check traps (SIGTRAP) on the
        // first buffer. `@Sendable` opts the closure out of that inference.
        // Do not capture `self`: hop audio levels through the Sendable bridge instead.
        let levelBridge = audioLevelBridge
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            onBuffer(converted)

            let rms = speechTapRMS(converted)
            let mapped = AudioLevelSmoother.mapDBFS(AudioLevelSmoother.dbFS(fromRMS: rms))
            levelBridge.ingest(mappedLevel: mapped, now: ProcessInfo.processInfo.systemUptime)
        }
        tapInstalled = true

        do {
            try audioEngine.start()
        } catch {
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            throw SpeechDictationError.audioEngineFailed(error.localizedDescription)
        }
        activeOutputFormat = outputFormat
        activeOnBuffer = onBuffer
        observeConfigurationChanges()
    }

    func stop() {
        activeOutputFormat = nil
        activeOnBuffer = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func formatCheck() -> MicrophoneFormatCheck {
        let inputNode = audioEngine.inputNode
        let hardware = inputNode.inputFormat(forBus: 0)
        let tap = inputNode.outputFormat(forBus: 0)
        return MicrophoneFormatCheck.check(
            hardwareSampleRate: hardware.sampleRate,
            hardwareChannels: hardware.channelCount,
            tapSampleRate: tap.sampleRate,
            tapChannels: tap.channelCount
        )
    }

    private func replaceEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        audioEngine = AVAudioEngine()
        needsNewEngine = false
    }

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        // Posted on an arbitrary thread; hop to the main actor before touching the engine.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
    }

    /// Input device or sample-rate change (Bluetooth headset connecting, the mic
    /// switching AirPods to the headset profile, ...). The engine has already stopped;
    /// resume on a fresh engine, or report the interruption instead of crashing.
    private func handleConfigurationChange() {
        needsNewEngine = true
        guard tapInstalled, let outputFormat = activeOutputFormat, let onBuffer = activeOnBuffer else {
            return
        }
        configurationRestarts += 1
        do {
            guard configurationRestarts <= Self.maxConfigurationRestarts else {
                throw SpeechDictationError.audioDeviceChanged
            }
            try startEngine(outputFormat: outputFormat, onBuffer: onBuffer)
        } catch {
            stop()
            onInterrupted?(error)
        }
    }
}

/// RMS of a converted PCM buffer. Must stay a free function so the `@Sendable` tap can call it.
func speechTapRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }

    if let channel = buffer.floatChannelData?[0] {
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }

    if let channel = buffer.int16ChannelData?[0] {
        var sum: Float = 0
        let scale: Float = 1 / 32768
        for index in 0..<count {
            let sample = Float(channel[index]) * scale
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }

    return 0
}
