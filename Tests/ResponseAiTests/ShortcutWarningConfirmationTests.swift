import Carbon
import XCTest
@testable import ResAICore
@testable import ResponseAi

@MainActor
final class ShortcutWarningConfirmationTests: XCTestCase {
    private var asked: [(ShortcutAction, ShortcutTrigger, ShortcutWarning)] = []

    private func makeController(answer: Bool) -> AppController {
        UserDefaults.standard.removeObject(forKey: AppShortcuts.DefaultsKey.shortcuts)
        let controller = AppController(
            permissionManager: AccessibilityPermissionManager(
                accessibilityTrustCheck: { false },
                accessibilityPromptRequest: { false },
                inputMonitoringAccessCheck: { false },
                inputMonitoringAccessRequest: { false }
            ),
            systemSettingsURLOpener: { _ in true }
        )
        controller.confirmShortcutWarning = { [weak self] action, trigger, warning in
            self?.asked.append((action, trigger, warning))
            return answer
        }
        return controller
    }

    private func finish(_ controller: AppController) {
        controller.shutDown()
        UserDefaults.standard.removeObject(forKey: AppShortcuts.DefaultsKey.shortcuts)
    }

    private let bareJ = ShortcutTrigger.key(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: []))

    func testDeclinedWarningKeepsThePreviousShortcut() {
        let controller = makeController(answer: false)
        defer { finish(controller) }

        controller.applyShortcut(bareJ, for: .rewrite)

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, .rewrite)
        if case .typesCharacter = asked.first?.2 {} else {
            XCTFail("expected a typesCharacter warning, got \(String(describing: asked.first?.2))")
        }
        XCTAssertEqual(controller.shortcuts.rewrite, AppShortcuts.defaultRewrite)
        XCTAssertNil(controller.shortcutErrors[.rewrite])
    }

    func testAcceptedWarningRegistersTheShortcut() {
        let controller = makeController(answer: true)
        defer { finish(controller) }

        controller.applyShortcut(bareJ, for: .rewrite)
        controller.applyShortcut(.modifierChord([.control]), for: .quickMenu)

        XCTAssertEqual(asked.map(\.0), [.rewrite, .quickMenu])
        XCTAssertEqual(asked.last?.2, .modifierOnly("⌃"))
        XCTAssertEqual(controller.shortcuts.rewrite, bareJ)
        XCTAssertEqual(controller.shortcuts.quickMenu, .modifierChord([.control]))
    }

    func testOrdinaryCombinationIsRegisteredWithoutAsking() {
        let controller = makeController(answer: false)
        defer { finish(controller) }
        let optionR = ShortcutTrigger.key(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .option]))

        controller.applyShortcut(optionR, for: .restore)

        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(controller.shortcuts.restore, optionR)
    }

    func testDuplicateIsRefusedBeforeAsking() {
        let controller = makeController(answer: true)
        defer { finish(controller) }

        controller.applyShortcut(AppShortcuts.defaultRestore, for: .rewrite)

        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(controller.shortcuts.rewrite, AppShortcuts.defaultRewrite)
        XCTAssertEqual(controller.shortcutErrors[.rewrite], ShortcutValidationError.duplicate(.restore).errorDescription)
    }
}
