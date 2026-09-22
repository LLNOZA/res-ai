import AVFAudio
import Foundation
import Speech

public struct DictationTranscript: Equatable, Sendable {
    public var finalizedText: String
    public var volatileText: String

    public var displayText: String { finalizedText + volatileText }

    public init(finalizedText: String = "", volatileText: String = "") {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
    }
}

public enum SpeechDictationError: Error, LocalizedError, Sendable {
    case unsupportedOS
    case microphoneDenied
    case localeUnsupported(String)
    case assetsUnavailable(String)
    case audioEngineFailed(String)
    case alreadyRunning
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "On-device SpeechAnalyzer dictation requires macOS 26 or later."
        case .microphoneDenied:
            "Microphone access was denied."
        case .localeUnsupported(let locale):
            "No on-device speech model is available for locale \(locale)."
        case .assetsUnavailable(let detail):
            "Speech model assets are unavailable: \(detail)"
        case .audioEngineFailed(let detail):
            "Audio capture failed: \(detail)"
        case .alreadyRunning:
            "Dictation is already running."
        case .notRunning:
            "Dictation is not running."
        }
    }
}

@MainActor
public protocol SpeechDictating: AnyObject {
    var engineName: String { get }
    var isRunning: Bool { get }
    /// Whether this engine can currently accept a session without reporting a
    /// known permission/availability failure.  A default keeps test doubles and
    /// older clients source-compatible.
    var isReady: Bool { get }
    /// Called on the main actor whenever finalized or volatile text changes.
    var onTranscriptUpdate: ((DictationTranscript) -> Void)? { get set }
    /// Called on the main actor as soon as the microphone tap is live (before analyzer setup).
    var onCaptureStarted: (() -> Void)? { get set }
    /// Called on the main actor with a smoothed 0…1 microphone level (throttled to ≤ 30 Hz).
    var onAudioLevel: ((Float) -> Void)? { get set }
    /// Called on the main actor when a running session fails and is torn down.
    var onError: ((Error) -> Void)? { get set }
    /// Ensure microphone permission + on-device model assets for the locale. Downloads assets if missing.
    func prepare(locale: Locale) async throws
    func start(locale: Locale) async throws
    /// Stops audio capture, finalizes analysis, and returns the complete final transcript.
    func stop() async throws -> DictationTranscript
    func cancel()
}

public extension SpeechDictating {
    var isReady: Bool { !isRunning }
}

@MainActor
public enum SpeechDictationEngineFactory {
    /// SpeechAnalyzer on macOS 26+; SFSpeechRecognizer on earlier supported versions.
    public static func make() -> any SpeechDictating {
        if #available(macOS 26.0, *) {
            SpeechAnalyzerDictationEngine()
        } else {
            LegacySpeechRecognizerEngine()
        }
    }

    public static var isSupported: Bool { true }

    public static var engineName: String {
        if #available(macOS 26.0, *) {
            "SpeechAnalyzer"
        } else {
            "SFSpeechRecognizer"
        }
    }
}

@MainActor
public enum MicrophonePermission {
    public static func status() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    public static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@available(macOS 26.0, *)
@MainActor
public final class SpeechAnalyzerDictationEngine: SpeechDictating {
    public let engineName = "SpeechAnalyzer"
    public private(set) var isRunning = false
    public var isReady: Bool {
        !isRunning
            && finalizingGeneration == nil
            && MicrophonePermission.status() == .granted
            && preparedLocale != nil
            && !analyzerFormats.isEmpty
    }
    public var onTranscriptUpdate: ((DictationTranscript) -> Void)?
    public var onCaptureStarted: (() -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    public var onError: ((Error) -> Void)?

    private let capture = MicrophoneCapture()
    private var transcript = DictationTranscript()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var warmAnalyzer: SpeechAnalyzer?
    private var warmTranscriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Error>?
    private var analyzerSetupTask: Task<Void, Error>?
    private var reservedLocale: Locale?
    private var preparedLocale: Locale?
    private var localeCache = PreparedLocaleCache()
    private var analyzerFormats: [String: AVAudioFormat] = [:]
    private var sessionGeneration = 0
    private var startAttemptID: UInt64 = 0
    private var finalizingGeneration: Int?
    private var audioSmoother = AudioLevelSmoother()

    public init() {}

    /// Permission, assets, locale/format cache, and a warm analyzer. Never starts the microphone.
    public func prepare(locale: Locale) async throws {
        try Task.checkCancellation()
        if isPrepared(for: locale), MicrophonePermission.status() == .granted {
            return
        }

        try Task.checkCancellation()
        let granted = await MicrophonePermission.request()
        guard granted else { throw SpeechDictationError.microphoneDenied }
        try Task.checkCancellation()

        if let preparedLocale, PreparedLocaleCache.identifier(preparedLocale) != PreparedLocaleCache.identifier(locale),
           localeCache.entry(for: locale) == nil {
            invalidatePreparedState()
        }

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechDictationError.localeUnsupported(locale.identifier)
        }
        try Task.checkCancellation()

        let transcriber = makeTranscriber(locale: resolved)

        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        try Task.checkCancellation()
        if !installed.contains(resolved.identifier(.bcp47)) {
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                    throw SpeechDictationError.assetsUnavailable(
                        "No installation request for locale \(resolved.identifier(.bcp47))"
                    )
                }
                try await request.downloadAndInstall()
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SpeechDictationError {
                throw error
            } catch {
                throw SpeechDictationError.assetsUnavailable(error.localizedDescription)
            }
        }

        let resolvedID = PreparedLocaleCache.identifier(resolved)
        if let reservedLocale, PreparedLocaleCache.identifier(reservedLocale) != resolvedID {
            let previous = reservedLocale
            self.reservedLocale = nil
            _ = await AssetInventory.release(reservedLocale: previous)
        }
        if self.reservedLocale == nil {
            _ = try? await AssetInventory.reserve(locale: resolved)
            reservedLocale = resolved
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechDictationError.audioEngineFailed("No compatible analyzer audio format.")
        }
        try Task.checkCancellation()

        localeCache.store(
            requested: locale,
            resolved: resolved,
            sampleRate: analyzerFormat.sampleRate,
            channelCount: UInt32(analyzerFormat.channelCount)
        )
        analyzerFormats[PreparedLocaleCache.identifier(locale)] = analyzerFormat
        analyzerFormats[PreparedLocaleCache.identifier(resolved)] = analyzerFormat
        preparedLocale = resolved

        if warmAnalyzer == nil {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            do {
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
                try Task.checkCancellation()
                warmTranscriber = transcriber
                warmAnalyzer = analyzer
            } catch {
                await analyzer.cancelAndFinishNow()
                if Task.isCancelled {
                    throw error
                }
            }
        }
    }

    public func start(locale: Locale) async throws {
        guard !isRunning, finalizingGeneration == nil else { throw SpeechDictationError.alreadyRunning }
        startAttemptID &+= 1
        let attemptID = startAttemptID
        let startGeneration = sessionGeneration

        do {
            try await prepare(locale: locale)
            try Task.checkCancellation()
            guard !isRunning, sessionGeneration == startGeneration else {
                throw SpeechDictationError.notRunning
            }
            try await beginSession(locale: locale)
        } catch {
            // A stop may deliberately race setup. In that case stop() owns
            // teardown; do not let the older start task reset the finalizing
            // session or cancel the analyzer that stop is draining.
            if startAttemptID == attemptID,
               finalizingGeneration == nil {
                tearDownSession()
            }
            throw error
        }
    }

    public func stop() async throws -> DictationTranscript {
        guard isRunning else { throw SpeechDictationError.notRunning }
        // Invalidate any start task that is still waiting for analyzer setup.
        // The stop path below will perform the bounded teardown instead.
        startAttemptID &+= 1
        // Keep this generation alive for final results, while blocking a new start
        // until finalization completes or cancellation invalidates the generation.
        let stoppingGeneration = sessionGeneration
        let transcriptAtStop = transcript
        finalizingGeneration = stoppingGeneration
        stopAudioCapture()
        capture.audioLevelBridge.publish = nil
        inputContinuation?.finish()
        inputContinuation = nil
        isRunning = false

        // Let the mic-first setup task attach the analyzer and consume the
        // already-buffered audio before finalizing. Cancelling it immediately
        // can discard speech captured while the analyzer was warming up. The
        // bounded wait still guarantees that a stuck framework call cannot
        // hold the stop path indefinitely.
        let stopDeadline = ProcessInfo.processInfo.systemUptime + 3.5
        func timeout(upTo seconds: TimeInterval) -> Duration? {
            let remaining = min(seconds, stopDeadline - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { return nil }
            return .milliseconds(max(1, Int((remaining * 1_000).rounded(.down))))
        }

        if let setupTask = analyzerSetupTask {
            let setupFinished: Bool
            if let setupTimeout = timeout(upTo: 0.4) {
                setupFinished = await VoiceLifecycleTimeout.run(timeout: setupTimeout) {
                    do {
                        try await setupTask.value
                    } catch {
                        // Setup failure is reflected by the analyzer state
                        // below; stop still owns session cleanup.
                    }
                    return true
                } ?? false
            } else {
                setupFinished = false
            }
            if !setupFinished {
                setupTask.cancel()
            }
            guard sessionGeneration == stoppingGeneration,
                  finalizingGeneration == stoppingGeneration else { return transcriptAtStop }
            analyzerSetupTask = nil
        }

        guard sessionGeneration == stoppingGeneration,
              finalizingGeneration == stoppingGeneration else { return transcriptAtStop }
        let analyzerToFinalize = analyzer

        if let analyzerToFinalize {
            let finalizeTimeout = timeout(upTo: 1.5) ?? .milliseconds(1)
            let cancelTimeout = timeout(upTo: 0.2) ?? .milliseconds(1)
            await finalizeAnalyzer(
                analyzerToFinalize,
                timeout: finalizeTimeout,
                cancelTimeout: cancelTimeout
            )
        }

        guard sessionGeneration == stoppingGeneration,
              finalizingGeneration == stoppingGeneration else { return transcriptAtStop }
        if let resultsTask, let resultsTimeout = timeout(upTo: 0.4) {
            _ = await VoiceLifecycleTimeout.run(timeout: resultsTimeout) {
                await resultsTask.value
                return true
            }
        }
        guard sessionGeneration == stoppingGeneration,
              finalizingGeneration == stoppingGeneration else { return transcriptAtStop }
        if let analyzerTask, let analyzerTimeout = timeout(upTo: 0.4) {
            _ = await VoiceLifecycleTimeout.run(timeout: analyzerTimeout) {
                _ = await analyzerTask.result
                return true
            }
        }

        let ownsStoppedSession = !isRunning
            && sessionGeneration == stoppingGeneration
            && finalizingGeneration == stoppingGeneration
        if ownsStoppedSession, !transcript.volatileText.isEmpty {
            transcript.finalizedText += transcript.volatileText
            transcript.volatileText = ""
            onTranscriptUpdate?(transcript)
        }

        let finished = ownsStoppedSession ? transcript : transcriptAtStop
        if ownsStoppedSession {
            finalizingGeneration = nil
            sessionGeneration += 1
            analyzerSetupTask?.cancel()
            analyzerSetupTask = nil
            resultsTask?.cancel()
            resultsTask = nil
            analyzerTask?.cancel()
            analyzerTask = nil
            analyzer = nil
            transcriber = nil
            rebuildWarmAnalyzerInBackground()
        }
        return finished
    }

    public func cancel() {
        startAttemptID &+= 1
        tearDownSession()
    }

    /// Microphone tap + `AVAudioEngine.start` first; analyzer construction second.
    /// Newest-buffering (~10 s) keeps audio produced before the analyzer is ready
    /// without letting a stalled consumer grow unbounded.
    private func beginSession(locale: Locale) async throws {
        sessionGeneration += 1
        let generation = sessionGeneration

        let resolved = try resolvedLocale(locale)
        guard let analyzerFormat = cachedFormat(for: resolved) ?? cachedFormat(for: locale) else {
            throw SpeechDictationError.audioEngineFailed("No compatible analyzer audio format.")
        }

        transcript = DictationTranscript()
        onTranscriptUpdate?(transcript)

        // 4096-frame tap buffers. Seconds per buffer = 4096 / sampleRate.
        // Keep ~10 s of newest audio (16 kHz → ~39 buffers; 48 kHz → ~117).
        let secondsPerBuffer = 4096.0 / analyzerFormat.sampleRate
        let newestCount = max(8, Int((10.0 / max(secondsPerBuffer, 0.001)).rounded(.up)))
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(newestCount)
        )
        inputContinuation = continuation

        audioSmoother = AudioLevelSmoother()
        capture.audioLevelBridge.reset()
        capture.audioLevelBridge.publish = { [weak self] mapped in
            self?.publishSmoothedLevel(mapped, generation: generation)
        }

        try installMicrophoneTap(analyzerFormat: analyzerFormat, continuation: continuation)
        isRunning = true
        onCaptureStarted?()

        let setupTask = Task { @MainActor [weak self] in
            guard let self else { throw SpeechDictationError.notRunning }
            try await self.attachAnalyzer(
                resolved: resolved,
                analyzerFormat: analyzerFormat,
                stream: stream,
                generation: generation
            )
        }
        analyzerSetupTask = setupTask
        try await setupTask.value
        try ensureCurrentSession(generation)
    }

    private func attachAnalyzer(
        resolved: Locale,
        analyzerFormat: AVAudioFormat,
        stream: AsyncStream<AnalyzerInput>,
        generation: Int
    ) async throws {
        try ensureCurrentSession(generation, allowFinalizing: true)

        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let alreadyPrepared: Bool
        if let warmTranscriber, let warmAnalyzer {
            transcriber = warmTranscriber
            analyzer = warmAnalyzer
            self.warmTranscriber = nil
            self.warmAnalyzer = nil
            alreadyPrepared = true
        } else {
            transcriber = makeTranscriber(locale: resolved)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            alreadyPrepared = false
        }

        do {
            try ensureCurrentSession(generation, allowFinalizing: true)
            self.transcriber = transcriber
            self.analyzer = analyzer

            if !alreadyPrepared {
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
                try ensureCurrentSession(generation, allowFinalizing: true)
            }

            resultsTask = Task { @MainActor [weak self] in
                do {
                    for try await result in transcriber.results {
                        let piece = String(result.text.characters)
                        self?.apply(resultText: piece, isFinal: result.isFinal, generation: generation)
                    }
                } catch {
                    self?.handleAnalyzerError(error, generation: generation)
                }
            }

            analyzerTask = Task { @MainActor [weak self] in
                do {
                    try await analyzer.start(inputSequence: stream)
                } catch {
                    self?.handleAnalyzerError(error, generation: generation)
                }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            if self.analyzer === analyzer {
                self.analyzer = nil
                self.transcriber = nil
            }
            throw error
        }
    }

    private func installMicrophoneTap(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        try capture.start(outputFormat: analyzerFormat) { converted in
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func publishSmoothedLevel(_ mapped: Float, generation: Int) {
        guard isRunning, sessionGeneration == generation else { return }
        let smoothed = audioSmoother.push(mapped)
        onAudioLevel?(smoothed)
    }

    private func apply(resultText: String, isFinal: Bool, generation: Int) {
        guard sessionGeneration == generation,
              isRunning || finalizingGeneration == generation
        else { return }
        if isFinal {
            transcript.finalizedText += resultText
            transcript.volatileText = ""
        } else {
            transcript.volatileText = resultText
        }
        onTranscriptUpdate?(transcript)
    }

    private func stopAudioCapture() {
        capture.stop()
    }

    private func handleAnalyzerError(_ error: Error, generation: Int) {
        guard isRunning, finalizingGeneration == nil, sessionGeneration == generation else { return }
        tearDownSession()
        onError?(error)
    }

    private func tearDownSession() {
        isRunning = false
        finalizingGeneration = nil
        sessionGeneration += 1
        stopAudioCapture()
        capture.audioLevelBridge.publish = nil
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzerSetupTask?.cancel()
        analyzerSetupTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil

        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }

        analyzer = nil
        transcriber = nil
        transcript = DictationTranscript()
        rebuildWarmAnalyzerInBackground()
    }

    private func invalidatePreparedState() {
        localeCache.removeAll()
        analyzerFormats.removeAll()
        preparedLocale = nil
        if let analyzer = warmAnalyzer {
            warmAnalyzer = nil
            warmTranscriber = nil
            Task {
                await analyzer.cancelAndFinishNow()
            }
        } else {
            warmAnalyzer = nil
            warmTranscriber = nil
        }
        if let reservedLocale {
            let locale = reservedLocale
            self.reservedLocale = nil
            Task {
                _ = await AssetInventory.release(reservedLocale: locale)
            }
        }
    }

    private func rebuildWarmAnalyzerInBackground() {
        guard let preparedLocale, let format = cachedFormat(for: preparedLocale) else {
            return
        }
        let locale = preparedLocale
        let preparedIdentifier = PreparedLocaleCache.identifier(locale)
        Task { @MainActor [weak self] in
            guard let self, !self.isRunning, self.warmAnalyzer == nil else { return }
            do {
                let transcriber = self.makeTranscriber(locale: locale)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.prepareToAnalyze(in: format)
                guard !self.isRunning,
                      self.warmAnalyzer == nil,
                      self.preparedLocale.map(PreparedLocaleCache.identifier) == preparedIdentifier
                else {
                    await analyzer.cancelAndFinishNow()
                    return
                }
                self.warmTranscriber = transcriber
                self.warmAnalyzer = analyzer
            } catch {
                // Next session builds a fresh pair.
            }
        }
    }

    private func isPrepared(for locale: Locale) -> Bool {
        localeCache.isPrepared(for: locale) && reservedLocale != nil
    }

    private func resolvedLocale(_ locale: Locale) throws -> Locale {
        if let identifier = localeCache.entry(for: locale)?.resolvedIdentifier {
            return Locale(identifier: identifier)
        }
        if let preparedLocale {
            return preparedLocale
        }
        throw SpeechDictationError.localeUnsupported(locale.identifier)
    }

    private func cachedFormat(for locale: Locale) -> AVAudioFormat? {
        analyzerFormats[PreparedLocaleCache.identifier(locale)]
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private func ensureCurrentSession(_ generation: Int, allowFinalizing: Bool = false) throws {
        let sessionIsActive = isRunning || (allowFinalizing && finalizingGeneration == generation)
        guard sessionIsActive, sessionGeneration == generation else {
            throw SpeechDictationError.notRunning
        }
    }

    private func finalizeAnalyzer(
        _ analyzer: SpeechAnalyzer,
        timeout: Duration,
        cancelTimeout: Duration
    ) async {
        let finished = await VoiceLifecycleTimeout.run(
            timeout: timeout
        ) {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                return false
            }
        } ?? false
        if !finished {
            _ = await VoiceLifecycleTimeout.run(timeout: cancelTimeout) {
                await analyzer.cancelAndFinishNow()
                return true
            }
        }
    }
}
