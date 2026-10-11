import XCTest
@testable import ResAICore
@testable import ResponseAi

/// A held modifier-only voice trigger in hold mode that turns out to be part of
/// another shortcut must never confirm (and therefore never insert text).
@MainActor
final class VoiceHotKeyCancelTests: XCTestCase {
    private final class FakeEngine: SpeechDictating {
        let engineName = "fake"
        var isRunning = false
        var onTranscriptUpdate: ((DictationTranscript) -> Void)?
        var onCaptureStarted: (() -> Void)?
        var onAudioLevel: ((Float) -> Void)?
        var onError: ((Error) -> Void)?
        var stopCount = 0

        func prepare(locale: Locale) async throws {}
        func start(locale: Locale) async throws { isRunning = true }
        func stop() async throws -> DictationTranscript {
            stopCount += 1
            isRunning = false
            return DictationTranscript(finalizedText: "should not be inserted")
        }
        func cancel() { isRunning = false }
    }

    private var environments: [AppEnvironment] = []

    override func tearDown() async throws {
        environments.forEach { $0.discard() }
        environments.removeAll()
        try await super.tearDown()
    }

    private func makeController(engine: FakeEngine) -> VoiceInputController {
        let environment = AppEnvironment.isolated()
        environments.append(environment)
        let controller = VoiceInputController(
            reader: AccessibilityReader(),
            replacer: TextReplacer(),
            permissionManager: AccessibilityPermissionManager(
                accessibilityTrustCheck: { false },
                accessibilityPromptRequest: { false },
                inputMonitoringAccessCheck: { false },
                inputMonitoringAccessRequest: { false }
            ),
            engine: engine,
            claudeAPIKeyProvider: { nil },
            environment: environment
        )
        controller.settings.activationMode = .holdOrTap
        return controller
    }

    func testCancelledHoldNeverStopsTheEngineOrInserts() async {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)
        var messages: [HUDMessage] = []
        controller.onHUDMessage = { messages.append($0) }

        controller.hotKeyPressed()
        messages.removeAll()
        controller.hotKeyCancelled()
        // A late release (lost ordering) must not confirm either.
        controller.hotKeyReleased()
        await Task.yield()

        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(messages.contains { $0.title == "音声入力を中止しました" })
    }

    func testCancelWithoutPressIsIgnored() {
        let engine = FakeEngine()
        let controller = makeController(engine: engine)

        controller.hotKeyCancelled()

        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertFalse(controller.isBusy)
    }

    func testActivationModeChangeIsReported() {
        let controller = makeController(engine: FakeEngine())
        var modes: [VoiceActivationMode] = []
        controller.onActivationModeChange = { modes.append($0) }

        controller.settings.activationMode = .toggleOnly
        controller.settings.cleanupEnabled.toggle()
        controller.settings.activationMode = .holdOrTap

        XCTAssertEqual(modes, [.toggleOnly, .holdOrTap])
    }
}
