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

/// Shared microphone tap used by SpeechAnalyzer and SFSpeechRecognizer engines.
/// The tap block runs on the audio render queue and must not capture MainActor state.
@MainActor
final class MicrophoneCapture {
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    let audioLevelBridge = AudioLevelBridge()

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        let inputNode = audioEngine.inputNode
        audioEngine.prepare()
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechDictationError.audioEngineFailed("Microphone input format is unavailable.")
        }
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
    }

    func stop() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
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
