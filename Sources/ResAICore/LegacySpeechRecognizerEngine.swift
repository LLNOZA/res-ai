import AVFAudio
import Foundation
import os
import Speech

/// One recognition callback, reduced to Sendable values before it leaves the Speech queue.
struct LegacyRecognitionEvent: Equatable, Sendable {
    var text: String?
    var isFinal: Bool
    var errorDescription: String?

    init(text: String? = nil, isFinal: Bool = false, errorDescription: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.errorDescription = errorDescription
    }
}

@MainActor
protocol LegacyRecognitionTasking: AnyObject {
    func cancel()
}

@MainActor
protocol LegacySpeechRecognizing: AnyObject {
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    func startTask(
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @MainActor @Sendable (LegacyRecognitionEvent) -> Void
    ) -> any LegacyRecognitionTasking
}

/// System services the macOS 14/15 engine depends on. Tests replace every member so the
/// legacy path runs on any OS without the microphone, TCC prompts, or Speech servers.
@MainActor
struct LegacySpeechServices {
    var speechAuthorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
    var requestSpeechAuthorization: () async -> SFSpeechRecognizerAuthorizationStatus
    var microphoneGranted: () -> Bool
    var requestMicrophone: () async -> Bool
    var makeRecognizer: (Locale) -> (any LegacySpeechRecognizing)?
    var makeCapture: () -> any AudioCapturing

    static var live: LegacySpeechServices {
        LegacySpeechServices(
            speechAuthorizationStatus: { SFSpeechRecognizer.authorizationStatus() },
            requestSpeechAuthorization: { await requestSystemSpeechAuthorization() },
            microphoneGranted: { MicrophonePermission.status() == .granted },
            requestMicrophone: { await MicrophonePermission.request() },
            makeRecognizer: { locale in
                SFSpeechRecognizer(locale: locale).map { SystemSpeechRecognizer($0) }
            },
            makeCapture: { MicrophoneCapture() }
        )
    }
}

/// On-device-preferred dictation via `SFSpeechRecognizer`, used on macOS < 26.
@MainActor
public final class LegacySpeechRecognizerEngine: SpeechDictating {
    public let engineName = "SFSpeechRecognizer"
    public private(set) var isRunning = false
    public var isReady: Bool {
        !isRunning
            && !stopping
            && services.speechAuthorizationStatus() == .authorized
            && services.microphoneGranted()
            && recognizer?.isAvailable == true
    }
    public var onTranscriptUpdate: ((DictationTranscript) -> Void)?
    public var onCaptureStarted: (() -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    public var onError: ((Error) -> Void)?

    /// A permanent failure (Dictation off, on-device assets missing) fails every
    /// request immediately; without a cap the restart loop never ends.
    static let maxConsecutiveRecognitionErrors = 3

    private let services: LegacySpeechServices
    private let capture: any AudioCapturing
    private let requestBox = SpeechAudioRequestBox()
    private var recognizer: (any LegacySpeechRecognizing)?
    private var recognitionTask: (any LegacyRecognitionTasking)?
    private var transcript = DictationTranscript()
    private var audioSmoother = AudioLevelSmoother()
    private var preparedLocaleIdentifier: String?
    private var recognitionGeneration = 0
    private var sessionGeneration = 0
    private var startAttemptID: UInt64 = 0
    private var stopping = false
    private var consecutiveRecognitionErrors = 0
    private var stopWaiter: (generation: Int, continuation: CheckedContinuation<DictationTranscript, Never>)?
    private var stopTimeoutTask: Task<Void, Never>?
    private var didLogServerFallback = false
    private let logger = Logger(subsystem: "ai.res.resai", category: "Speech")

    public convenience init() {
        self.init(services: .live)
    }

    init(services: LegacySpeechServices) {
        self.services = services
        self.capture = services.makeCapture()
    }

    /// True while `stop()` waits for the recognizer's final result.
    var isAwaitingFinalResult: Bool { stopWaiter != nil }

    public func prepare(locale: Locale) async throws {
        try Task.checkCancellation()
        if isPrepared(for: locale),
           services.speechAuthorizationStatus() == .authorized,
           services.microphoneGranted() {
            return
        }

        switch services.speechAuthorizationStatus() {
        case .authorized:
            break
        case .denied, .restricted:
            // Asking again shows nothing; only System Settings can change it.
            throw SpeechDictationError.speechRecognitionDenied
        default:
            let speechStatus = await services.requestSpeechAuthorization()
            guard speechStatus == .authorized else {
                throw SpeechDictationError.speechRecognitionDenied
            }
        }
        try Task.checkCancellation()

        let granted = await services.requestMicrophone()
        guard granted else { throw SpeechDictationError.microphoneDenied }
        try Task.checkCancellation()

        try attachRecognizer(locale: locale)
    }

    public func start(locale: Locale) async throws {
        guard !isRunning, !stopping else { throw SpeechDictationError.alreadyRunning }
        startAttemptID &+= 1
        let attemptID = startAttemptID
        sessionGeneration += 1
        let generation = sessionGeneration

        do {
            try await prepare(locale: locale)
            try Task.checkCancellation()
            guard sessionGeneration == generation, !isRunning else {
                throw SpeechDictationError.notRunning
            }
            try beginSession(generation: generation)
        } catch {
            if startAttemptID == attemptID {
                tearDownSession()
            }
            throw error
        }
    }

    public func stop() async throws -> DictationTranscript {
        guard isRunning else { throw SpeechDictationError.notRunning }

        stopping = true
        isRunning = false
        let stoppingGeneration = sessionGeneration
        let transcriptAtStop = transcript
        capture.stop()
        requestBox.endAudio()

        let generation = sessionGeneration
        let finished = await waitForFinalResult(timeoutSeconds: 3, generation: generation)
        let ownsStoppedSession = sessionGeneration == stoppingGeneration
        if ownsStoppedSession {
            tearDownRecognition()
            stopping = false
        }
        return ownsStoppedSession ? finished : transcriptAtStop
    }

    public func cancel() {
        startAttemptID &+= 1
        tearDownSession()
    }

    /// Microphone tap first; recognition request second. Pending buffers are queued until attached.
    private func beginSession(generation: Int) throws {
        guard sessionGeneration == generation, !Task.isCancelled else {
            throw SpeechDictationError.notRunning
        }
        transcript = DictationTranscript()
        onTranscriptUpdate?(transcript)
        stopping = false
        consecutiveRecognitionErrors = 0

        audioSmoother = AudioLevelSmoother()
        capture.audioLevelBridge.reset()
        capture.audioLevelBridge.publish = { [weak self] mapped in
            self?.publishSmoothedLevel(mapped, generation: generation)
        }
        capture.onInterrupted = { [weak self] error in
            guard let self, self.isRunning, self.sessionGeneration == generation else { return }
            self.failSession(error)
        }

        let format = try recognitionFormat()
        let box = requestBox
        try capture.start(outputFormat: format) { buffer in
            box.append(buffer)
        }
        isRunning = true
        onCaptureStarted?()

        try startRecognitionTask()
    }

    private func startRecognitionTask() throws {
        guard let recognizer else {
            throw SpeechDictationError.localeUnsupported(preparedLocaleIdentifier ?? "")
        }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        let request = makeRequest(recognizer: recognizer)
        requestBox.attach(request)

        recognitionTask = recognizer.startTask(request: request) { [weak self] event in
            self?.handleRecognition(event, generation: generation)
        }
    }

    private func handleRecognition(_ event: LegacyRecognitionEvent, generation: Int) {
        guard generation == recognitionGeneration else { return }

        if let errorDescription = event.errorDescription {
            if stopping {
                completeStop(generation: sessionGeneration)
            } else if isRunning {
                consecutiveRecognitionErrors += 1
                logger.error("SFSpeechRecognizer request failed count=\(self.consecutiveRecognitionErrors, privacy: .public): \(errorDescription, privacy: .public)")
                if consecutiveRecognitionErrors >= Self.maxConsecutiveRecognitionErrors {
                    failSession(SpeechDictationError.recognitionFailed(errorDescription))
                } else {
                    restartRecognition()
                }
            }
            return
        }

        guard let text = event.text else { return }
        if !text.isEmpty {
            consecutiveRecognitionErrors = 0
        }

        if event.isFinal {
            if !text.isEmpty {
                transcript.finalizedText += text
                transcript.volatileText = ""
                onTranscriptUpdate?(transcript)
            }
            if stopping {
                completeStop(generation: sessionGeneration)
            } else if isRunning {
                restartRecognition()
            }
        } else if isRunning || stopping {
            transcript.volatileText = text
            onTranscriptUpdate?(transcript)
        }
    }

    private func restartRecognition() {
        recognitionTask = nil
        requestBox.beginQueuing()
        do {
            try startRecognitionTask()
        } catch {
            logger.error("SFSpeechRecognizer request restart failed: \(error.localizedDescription, privacy: .public)")
            failSession(error)
        }
    }

    private func failSession(_ error: Error) {
        let callback = onError
        tearDownSession()
        callback?(error)
    }

    private func waitForFinalResult(timeoutSeconds: TimeInterval, generation: Int) async -> DictationTranscript {
        await withCheckedContinuation { continuation in
            // Never drop a waiter without resuming it.
            if let previous = stopWaiter {
                stopWaiter = nil
                previous.continuation.resume(returning: transcript)
            }
            stopTimeoutTask?.cancel()
            stopWaiter = (generation: generation, continuation: continuation)
            stopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.completeStop(generation: generation)
            }
        }
    }

    /// The only resume points are here and `tearDownRecognition`; both clear
    /// `stopWaiter` first, so a continuation is resumed exactly once.
    private func completeStop(generation: Int) {
        guard let stopWaiter, stopWaiter.generation == generation else { return }
        self.stopWaiter = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        if !transcript.volatileText.isEmpty {
            transcript.finalizedText += transcript.volatileText
            transcript.volatileText = ""
            onTranscriptUpdate?(transcript)
        }
        stopWaiter.continuation.resume(returning: transcript)
    }

    private func publishSmoothedLevel(_ mapped: Float, generation: Int) {
        guard isRunning, sessionGeneration == generation else { return }
        let smoothed = audioSmoother.push(mapped)
        onAudioLevel?(smoothed)
    }

    private func attachRecognizer(locale: Locale) throws {
        guard let recognizer = services.makeRecognizer(locale) else {
            throw SpeechDictationError.localeUnsupported(locale.identifier)
        }
        // Siri/Dictation turned off or no network for a server-only locale.
        guard recognizer.isAvailable else {
            throw SpeechDictationError.recognizerUnavailable(locale.identifier)
        }
        self.recognizer = recognizer
        preparedLocaleIdentifier = locale.identifier
        if !recognizer.supportsOnDeviceRecognition {
            logServerFallbackIfNeeded(locale: locale)
        }
    }

    private func makeRequest(recognizer: any LegacySpeechRecognizing) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if !recognizer.supportsOnDeviceRecognition {
            logServerFallbackIfNeeded(locale: Locale(identifier: preparedLocaleIdentifier ?? ""))
        }
        return request
    }

    private func logServerFallbackIfNeeded(locale: Locale) {
        guard !didLogServerFallback else { return }
        didLogServerFallback = true
        logger.notice(
            "SFSpeechRecognizer on-device recognition unavailable; using server. locale=\(locale.identifier, privacy: .public)"
        )
    }

    private func recognitionFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechDictationError.audioEngineFailed("Could not create recognition audio format.")
        }
        return format
    }

    private func isPrepared(for locale: Locale) -> Bool {
        recognizer != nil
            && recognizer?.isAvailable == true
            && preparedLocaleIdentifier == locale.identifier
    }

    private func tearDownRecognition() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.reset()
        capture.audioLevelBridge.publish = nil
        if let stopWaiter {
            self.stopWaiter = nil
            stopTimeoutTask?.cancel()
            stopTimeoutTask = nil
            stopWaiter.continuation.resume(returning: transcript)
        }
    }

    private func tearDownSession() {
        sessionGeneration += 1
        isRunning = false
        stopping = false
        capture.onInterrupted = nil
        capture.stop()
        tearDownRecognition()
        transcript = DictationTranscript()
    }
}

/// `SFSpeechRecognizer.requestAuthorization` calls back on an arbitrary queue. Kept
/// nonisolated with an explicit `@Sendable` handler: a MainActor-inherited closure
/// trips Swift 6's runtime isolation check and the process traps on macOS 14/15.
private func requestSystemSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            continuation.resume(returning: status)
        }
    }
}

@MainActor
private final class SystemSpeechRecognizer: LegacySpeechRecognizing {
    private let recognizer: SFSpeechRecognizer

    init(_ recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    var isAvailable: Bool { recognizer.isAvailable }
    var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }

    func startTask(
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @MainActor @Sendable (LegacyRecognitionEvent) -> Void
    ) -> any LegacyRecognitionTasking {
        // `@Sendable` keeps the result handler nonisolated whatever queue Speech uses.
        let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let event = LegacyRecognitionEvent(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                errorDescription: error?.localizedDescription
            )
            Task { @MainActor in
                handler(event)
            }
        }
        return SystemRecognitionTask(task)
    }
}

@MainActor
private final class SystemRecognitionTask: LegacyRecognitionTasking {
    private let task: SFSpeechRecognitionTask

    init(_ task: SFSpeechRecognitionTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// Lock-protected request so the audio-thread tap can append without touching MainActor state.
private final class SpeechAudioRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var pending: [AVAudioPCMBuffer] = []
    private var ended = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        if let request {
            request.append(buffer)
        } else {
            pending.append(buffer)
            trimPendingLocked()
        }
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        defer { lock.unlock() }
        ended = false
        self.request = request
        for buffer in pending {
            request.append(buffer)
        }
        pending.removeAll(keepingCapacity: true)
    }

    private func trimPendingLocked() {
        let durations = pending.map { buffer -> TimeInterval in
            let rate = buffer.format.sampleRate
            guard rate > 0 else { return 0 }
            return Double(buffer.frameLength) / rate
        }
        let kept = BoundedDurationPolicy.dropOldest(durations: durations, maxDuration: 10)
        if kept.count < pending.count {
            pending.removeFirst(pending.count - kept.count)
        }
    }

    func beginQueuing() {
        lock.lock()
        request = nil
        ended = false
        lock.unlock()
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        ended = true
        request?.endAudio()
    }

    func reset() {
        lock.lock()
        request = nil
        pending.removeAll()
        ended = false
        lock.unlock()
    }
}
