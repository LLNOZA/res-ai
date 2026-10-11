import AVFAudio
import Speech
import XCTest
@testable import ResAICore

/// Drives the macOS 14/15 `SFSpeechRecognizer` engine with fakes so the path runs
/// on any OS without the microphone, TCC prompts, or Apple's speech servers.
@MainActor
final class LegacySpeechRecognizerEngineTests: XCTestCase {
    private final class FakeTask: LegacyRecognitionTasking {
        var cancelCount = 0
        func cancel() { cancelCount += 1 }
    }

    private final class FakeRecognizer: LegacySpeechRecognizing {
        var isAvailable = true
        var supportsOnDeviceRecognition = true
        var handlers: [@MainActor @Sendable (LegacyRecognitionEvent) -> Void] = []
        var requests: [SFSpeechAudioBufferRecognitionRequest] = []

        func startTask(
            request: SFSpeechAudioBufferRecognitionRequest,
            handler: @escaping @MainActor @Sendable (LegacyRecognitionEvent) -> Void
        ) -> any LegacyRecognitionTasking {
            requests.append(request)
            handlers.append(handler)
            return FakeTask()
        }

        func send(_ event: LegacyRecognitionEvent) {
            handlers.last?(event)
        }
    }

    private final class FakeCapture: AudioCapturing {
        let audioLevelBridge = AudioLevelBridge()
        var onInterrupted: ((Error) -> Void)?
        var startError: Error?
        var startCount = 0
        var stopCount = 0
        var isCapturing = false

        func start(outputFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            if let startError { throw startError }
            startCount += 1
            isCapturing = true
        }

        func stop() {
            stopCount += 1
            isCapturing = false
        }
    }

    @MainActor
    private final class Harness {
        var authorization: SFSpeechRecognizerAuthorizationStatus = .authorized
        var authorizationAfterRequest: SFSpeechRecognizerAuthorizationStatus = .authorized
        var authorizationRequests = 0
        var microphoneGranted = true
        var recognizer: FakeRecognizer? = FakeRecognizer()
        let capture = FakeCapture()

        func makeEngine() -> LegacySpeechRecognizerEngine {
            LegacySpeechRecognizerEngine(services: LegacySpeechServices(
                speechAuthorizationStatus: { [unowned self] in self.authorization },
                requestSpeechAuthorization: { [unowned self] in
                    self.authorizationRequests += 1
                    self.authorization = self.authorizationAfterRequest
                    return self.authorization
                },
                microphoneGranted: { [unowned self] in self.microphoneGranted },
                requestMicrophone: { [unowned self] in self.microphoneGranted },
                makeRecognizer: { [unowned self] _ in self.recognizer },
                makeCapture: { [unowned self] in self.capture }
            ))
        }
    }

    private let locale = Locale(identifier: "ja_JP")

    func testDeniedOrRestrictedSpeechAuthorizationFailsWithoutAsking() async {
        for status in [SFSpeechRecognizerAuthorizationStatus.denied, .restricted] {
            let harness = Harness()
            harness.authorization = status
            let engine = harness.makeEngine()

            await assertThrows(SpeechDictationError.speechRecognitionDenied) {
                try await engine.start(locale: self.locale)
            }
            XCTAssertEqual(harness.authorizationRequests, 0)
            XCTAssertEqual(harness.capture.startCount, 0)
            XCTAssertFalse(engine.isRunning)
            XCTAssertFalse(engine.isReady)
        }
    }

    func testNotDeterminedAsksOnceAndStopsWhenDenied() async {
        let harness = Harness()
        harness.authorization = .notDetermined
        harness.authorizationAfterRequest = .denied
        let engine = harness.makeEngine()

        await assertThrows(SpeechDictationError.speechRecognitionDenied) {
            try await engine.prepare(locale: self.locale)
        }
        XCTAssertEqual(harness.authorizationRequests, 1)
    }

    func testMissingOrUnavailableRecognizerIsAnErrorNotACrash() async {
        let missing = Harness()
        missing.recognizer = nil
        await assertThrows(SpeechDictationError.localeUnsupported("ja_JP")) {
            try await missing.makeEngine().start(locale: self.locale)
        }

        let unavailable = Harness()
        unavailable.recognizer?.isAvailable = false
        let engine = unavailable.makeEngine()
        await assertThrows(SpeechDictationError.recognizerUnavailable("ja_JP")) {
            try await engine.start(locale: self.locale)
        }
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(unavailable.capture.startCount, 0)
    }

    func testMicrophoneDeniedNeverStartsCapture() async {
        let harness = Harness()
        harness.microphoneGranted = false
        await assertThrows(SpeechDictationError.microphoneDenied) {
            try await harness.makeEngine().start(locale: self.locale)
        }
        XCTAssertEqual(harness.capture.startCount, 0)
    }

    func testCaptureStartFailureLeavesEngineStopped() async {
        let harness = Harness()
        harness.capture.startError = SpeechDictationError.audioDeviceChanged
        let engine = harness.makeEngine()
        await assertThrows(SpeechDictationError.audioDeviceChanged) {
            try await engine.start(locale: self.locale)
        }
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.isReady)
    }

    func testSecondStartWhileRunningIsRejected() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        try await engine.start(locale: locale)
        await assertThrows(SpeechDictationError.alreadyRunning) {
            try await engine.start(locale: self.locale)
        }
        XCTAssertEqual(harness.capture.startCount, 1)
        engine.cancel()
    }

    func testStopReturnsFinalTranscript() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        try await engine.start(locale: locale)
        XCTAssertTrue(engine.isRunning)
        let recognizer = try XCTUnwrap(harness.recognizer)
        recognizer.send(LegacyRecognitionEvent(text: "こんに"))

        let stopTask = Task { try await engine.stop() }
        try await waitUntil { engine.isAwaitingFinalResult }
        recognizer.send(LegacyRecognitionEvent(text: "こんにちは", isFinal: true))
        let transcript = try await stopTask.value

        XCTAssertEqual(transcript.finalizedText, "こんにちは")
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(harness.capture.isCapturing)
        // Late callbacks after the stop resumed must not resume the continuation again.
        recognizer.send(LegacyRecognitionEvent(text: "late", isFinal: true))
        recognizer.send(LegacyRecognitionEvent(errorDescription: "late error"))
        XCTAssertTrue(engine.isReady)
    }

    func testCancelDuringStopResumesTheWaiterOnce() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        try await engine.start(locale: locale)
        harness.recognizer?.send(LegacyRecognitionEvent(text: "途中"))

        let stopTask = Task { try await engine.stop() }
        try await waitUntil { engine.isAwaitingFinalResult }
        engine.cancel()
        _ = try await stopTask.value
        engine.cancel()
        XCTAssertFalse(engine.isAwaitingFinalResult)
        XCTAssertTrue(engine.isReady)
    }

    func testPermanentRecognitionFailureStopsInsteadOfRestartingForever() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        var errors: [Error] = []
        engine.onError = { errors.append($0) }
        try await engine.start(locale: locale)
        let recognizer = try XCTUnwrap(harness.recognizer)

        for _ in 0..<LegacySpeechRecognizerEngine.maxConsecutiveRecognitionErrors {
            recognizer.send(LegacyRecognitionEvent(errorDescription: "Siri and Dictation are disabled"))
        }

        XCTAssertEqual(recognizer.requests.count, LegacySpeechRecognizerEngine.maxConsecutiveRecognitionErrors)
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(harness.capture.isCapturing)
        XCTAssertEqual(errors.count, 1)
        if case SpeechDictationError.recognitionFailed = try XCTUnwrap(errors.first) {} else {
            XCTFail("expected recognitionFailed, got \(String(describing: errors.first))")
        }
    }

    func testRecognizedTextResetsTheRestartBudget() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        var errorCount = 0
        engine.onError = { _ in errorCount += 1 }
        try await engine.start(locale: locale)
        let recognizer = try XCTUnwrap(harness.recognizer)

        for _ in 0..<4 {
            recognizer.send(LegacyRecognitionEvent(errorDescription: "transient"))
            recognizer.send(LegacyRecognitionEvent(text: "続き"))
        }

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(errorCount, 0)
        engine.cancel()
    }

    func testInputDeviceChangeEndsSessionWithError() async throws {
        let harness = Harness()
        let engine = harness.makeEngine()
        var errors: [Error] = []
        engine.onError = { errors.append($0) }
        try await engine.start(locale: locale)

        harness.capture.onInterrupted?(SpeechDictationError.audioDeviceChanged)

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(harness.capture.onInterrupted, "a stale interruption cannot end the next session")
    }

    func testFactoryCanSelectTheLegacyEngine() {
        XCTAssertEqual(SpeechDictationEngineFactory.make(kind: .legacy).engineName, "SFSpeechRecognizer")
        XCTAssertEqual(
            SpeechDictationEngineFactory.preferredKind(environment: [SpeechDictationEngineFactory.forceLegacyEnvironmentKey: "1"]),
            .legacy
        )
        if #available(macOS 26.0, *) {
            XCTAssertEqual(SpeechDictationEngineFactory.preferredKind(environment: [:]), .speechAnalyzer)
        } else {
            XCTAssertEqual(SpeechDictationEngineFactory.preferredKind(environment: [:]), .legacy)
        }
    }

    func testMicrophoneFormatCheckRejectsFormatsThatWouldCrashInstallTap() {
        XCTAssertEqual(MicrophoneFormatCheck.check(hardwareSampleRate: 48_000, hardwareChannels: 1, tapSampleRate: 48_000, tapChannels: 1), .ok)
        XCTAssertEqual(MicrophoneFormatCheck.check(hardwareSampleRate: 0, hardwareChannels: 1, tapSampleRate: 48_000, tapChannels: 1), .unavailable)
        XCTAssertEqual(MicrophoneFormatCheck.check(hardwareSampleRate: 48_000, hardwareChannels: 0, tapSampleRate: 48_000, tapChannels: 1), .unavailable)
        XCTAssertEqual(MicrophoneFormatCheck.check(hardwareSampleRate: 48_000, hardwareChannels: 1, tapSampleRate: 0, tapChannels: 0), .unavailable)
        // Bluetooth headset switched to 16 kHz while the node still reports 48 kHz.
        XCTAssertEqual(MicrophoneFormatCheck.check(hardwareSampleRate: 16_000, hardwareChannels: 1, tapSampleRate: 48_000, tapChannels: 1), .mismatch)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }

    private func assertThrows(
        _ expected: SpeechDictationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                (error as? SpeechDictationError)?.errorDescription,
                expected.errorDescription,
                file: file,
                line: line
            )
        }
    }
}

final class DiagnosticPayloadSanitizerTests: XCTestCase {
    func testKeepsCrashAndHangReportsAndDropsMessages() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "timeStampBegin": "2026-10-10",
            "cpuExceptionDiagnostics": [["totalCPUTime": 1]],
            "crashDiagnostics": [[
                "callStackTree": ["callStacks": [["callStackRootFrames": [["binaryName": "ResponseAi", "offsetIntoBinaryTextSegment": 123]]]]],
                "diagnosticMetaData": [
                    "signal": 5,
                    "objectiveCexceptionReason": ["composedMessage": "typed text", "arguments": ["typed text"], "formatString": "%@"]
                ]
            ]],
            "hangDiagnostics": [["diagnosticMetaData": ["hangDuration": "3 sec"]]]
        ])

        let sanitized = try XCTUnwrap(DiagnosticPayloadSanitizer.sanitize(payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertEqual(Set(object.keys), ["timeStampBegin", "crashDiagnostics", "hangDiagnostics"])
        XCTAssertFalse(text.contains("typed text"))
        XCTAssertTrue(text.contains("ResponseAi"))
        XCTAssertTrue(text.contains("hangDuration"))
    }

    func testPayloadWithoutCrashOrHangIsSkipped() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["cpuExceptionDiagnostics": [["x": 1]], "crashDiagnostics": []])
        XCTAssertNil(DiagnosticPayloadSanitizer.sanitize(payload))
        XCTAssertNil(DiagnosticPayloadSanitizer.sanitize(Data("not json".utf8)))
    }
}
