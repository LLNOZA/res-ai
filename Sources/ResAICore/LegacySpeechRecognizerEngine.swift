import AVFAudio
import Foundation
import os
import Speech

/// On-device-preferred dictation via `SFSpeechRecognizer`, used on macOS < 26.
@MainActor
public final class LegacySpeechRecognizerEngine: SpeechDictating {
    public let engineName = "SFSpeechRecognizer"
    public private(set) var isRunning = false
    public var isReady: Bool {
        !isRunning
            && !stopping
            && SFSpeechRecognizer.authorizationStatus() == .authorized
            && MicrophonePermission.status() == .granted
            && recognizer?.isAvailable == true
    }
    public var onTranscriptUpdate: ((DictationTranscript) -> Void)?
    public var onCaptureStarted: (() -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    public var onError: ((Error) -> Void)?

    private let capture = MicrophoneCapture()
    private let requestBox = SpeechAudioRequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcript = DictationTranscript()
    private var audioSmoother = AudioLevelSmoother()
    private var preparedLocaleIdentifier: String?
    private var recognitionGeneration = 0
    private var sessionGeneration = 0
    private var startAttemptID: UInt64 = 0
    private var stopping = false
    private var stopWaiter: (generation: Int, continuation: CheckedContinuation<DictationTranscript, Never>)?
    private var stopTimeoutTask: Task<Void, Never>?
    private var didLogServerFallback = false
    private let logger = Logger(subsystem: "ai.res.resai", category: "Speech")

    public init() {}

    public func prepare(locale: Locale) async throws {
        try Task.checkCancellation()
        if isPrepared(for: locale),
           SFSpeechRecognizer.authorizationStatus() == .authorized,
           MicrophonePermission.status() == .granted {
            return
        }

        try Task.checkCancellation()
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw SpeechDictationError.assetsUnavailable("Speech recognition was denied.")
        }
        try Task.checkCancellation()

        let granted = await MicrophonePermission.request()
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

        audioSmoother = AudioLevelSmoother()
        capture.audioLevelBridge.reset()
        capture.audioLevelBridge.publish = { [weak self] mapped in
            self?.publishSmoothedLevel(mapped, generation: generation)
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

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil
            Task { @MainActor [weak self] in
                self?.handleRecognition(
                    text: text,
                    isFinal: isFinal,
                    hasError: hasError,
                    generation: generation
                )
            }
        }
    }

    private func handleRecognition(text: String?, isFinal: Bool, hasError: Bool, generation: Int) {
        guard generation == recognitionGeneration else { return }

        if hasError {
            if stopping {
                completeStop(generation: sessionGeneration)
            } else if isRunning {
                restartRecognition()
            }
            return
        }

        guard let text else { return }

        if isFinal {
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
            stopTimeoutTask?.cancel()
            stopWaiter = (generation: generation, continuation: continuation)
            stopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.completeStop(generation: generation)
            }
        }
    }

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
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechDictationError.localeUnsupported(locale.identifier)
        }
        self.recognizer = recognizer
        preparedLocaleIdentifier = locale.identifier
        if !recognizer.supportsOnDeviceRecognition {
            logServerFallbackIfNeeded(locale: locale)
        }
    }

    private func makeRequest(recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
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

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
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
        capture.stop()
        tearDownRecognition()
        transcript = DictationTranscript()
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
