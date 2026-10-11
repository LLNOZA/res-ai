import Carbon
import XCTest
@testable import ResAICore

final class ShortcutValidationTests: XCTestCase {
    private let shortcuts = AppShortcuts.defaults

    private func key(_ keyCode: Int, _ modifiers: ShortcutModifiers) -> ShortcutTrigger {
        .key(HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    func testAcceptsFreeModifierCombinations() {
        let accepted: [ShortcutTrigger] = [
            key(kVK_ANSI_R, [.command, .option]),
            key(kVK_ANSI_1, [.control, .shift]),
            key(kVK_ANSI_Slash, [.command, .control, .option, .shift]),
            key(kVK_Space, [.option]),
            key(kVK_LeftArrow, [.command, .control]),
            key(kVK_ANSI_J, [.command]),
            key(kVK_F5, [.shift])
        ]
        for trigger in accepted {
            XCTAssertNil(shortcuts.validationError(for: trigger, action: .rewrite), trigger.displayName)
        }
    }

    func testRejectsKeyWithoutModifierExceptF1ToF12() {
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_ANSI_J, []), action: .rewrite), .missingModifier)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_Space, []), action: .voice), .missingModifier)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_F13, []), action: .rewrite), .missingModifier)
        for code in KeyCodeNames.functionKeyCodes {
            XCTAssertNil(
                shortcuts.validationError(for: .key(HotKeyShortcut(keyCode: code, modifiers: [])), action: .formFill),
                "F-key \(code)"
            )
        }
    }

    func testRejectsShiftOnlyWithCharacterKeys() {
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_ANSI_J, [.shift]), action: .rewrite), .shiftOnly)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_ANSI_1, [.shift]), action: .restore), .shiftOnly)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_Space, [.shift]), action: .voice), .shiftOnly)
        XCTAssertNil(shortcuts.validationError(for: key(kVK_ANSI_J, [.shift, .option]), action: .rewrite))
    }

    func testRejectsDuplicatesAcrossActions() {
        XCTAssertEqual(
            shortcuts.validationError(for: .key(AppShortcuts.defaultRestore), action: .rewrite),
            .duplicate(.restore)
        )
        XCTAssertEqual(
            shortcuts.validationError(for: AppShortcuts.defaultVoiceTrigger, action: .quickMenu),
            .duplicate(.voice)
        )
        XCTAssertEqual(
            shortcuts.validationError(for: .key(AppShortcuts.defaultRewrite), action: .voice),
            .duplicate(.rewrite)
        )
        // Re-recording an action's own shortcut is not a conflict.
        XCTAssertNil(shortcuts.validationError(for: .key(AppShortcuts.defaultRewrite), action: .rewrite))
    }

    func testRejectsEveryReservedSystemShortcut() {
        for reserved in ReservedShortcut.all {
            for action in ShortcutAction.allCases {
                XCTAssertEqual(
                    shortcuts.validationError(for: .key(reserved.shortcut), action: action),
                    .reserved(reserved.name),
                    "\(reserved.name) \(reserved.shortcut)"
                )
            }
        }
    }

    func testReservedListCoversRequiredSystemShortcuts() {
        let required: [ShortcutTrigger] = [
            key(kVK_ANSI_Q, [.command]), key(kVK_ANSI_W, [.command]), key(kVK_ANSI_C, [.command]),
            key(kVK_ANSI_V, [.command]), key(kVK_ANSI_X, [.command]), key(kVK_ANSI_Z, [.command]),
            key(kVK_ANSI_A, [.command]), key(kVK_ANSI_S, [.command]), key(kVK_Tab, [.command]),
            key(kVK_Space, [.command]), key(kVK_Space, [.control]),
            key(kVK_ANSI_3, [.command, .shift]), key(kVK_ANSI_4, [.command, .shift]),
            key(kVK_ANSI_5, [.command, .shift])
        ]
        let reserved = Set(ReservedShortcut.all.map { ShortcutTrigger.key($0.shortcut) })
        for trigger in required {
            XCTAssertTrue(reserved.contains(trigger), trigger.displayName)
        }
        // The defaults themselves must never be reserved.
        for action in ShortcutAction.allCases {
            XCTAssertFalse(reserved.contains(AppShortcuts.defaults.trigger(for: action)), action.rawValue)
        }
    }

    func testModifierOnlyIsVoiceOnlyAndNeedsTwoModifiers() {
        let chord = ShortcutTrigger.modifierChord([.command, .shift])
        for action in ShortcutAction.allCases where action != .voice {
            XCTAssertEqual(shortcuts.validationError(for: chord, action: action), .modifierOnlyNotAllowed)
        }
        XCTAssertNil(shortcuts.validationError(for: chord, action: .voice))
        XCTAssertNil(shortcuts.validationError(for: .fnCommand, action: .voice))
        XCTAssertNil(shortcuts.validationError(for: .modifierChord([.function, .option]), action: .voice))
        XCTAssertEqual(
            shortcuts.validationError(for: .modifierChord([.command]), action: .voice),
            .tooFewModifiers
        )
    }

    func testRejectsModifierKeysAndFnWithOrdinaryKeys() {
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_Command, [.shift]), action: .rewrite), .unsupportedKey)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_ANSI_J, [.function, .command]), action: .rewrite), .unsupportedKey)
    }

    func testErrorsExplainTheReason() {
        let errors: [ShortcutValidationError] = [
            .missingModifier, .shiftOnly, .modifierOnlyNotAllowed, .tooFewModifiers,
            .unsupportedKey, .duplicate(.restore), .reserved("コピー")
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        XCTAssertEqual(ShortcutValidationError.duplicate(.restore).errorDescription, "「復元」で使用中です。")
    }

    func testSetStoresTriggerAndIgnoresChordForKeyOnlyActions() {
        var shortcuts = AppShortcuts.defaults
        let optionR = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .option])

        shortcuts.set(.key(optionR), for: .restore)
        shortcuts.set(.fnCommand, for: .voice)
        shortcuts.set(.modifierChord([.command, .shift]), for: .rewrite)

        XCTAssertEqual(shortcuts.restore, optionR)
        XCTAssertEqual(shortcuts.voiceTrigger, .fnCommand)
        XCTAssertEqual(shortcuts.rewrite, AppShortcuts.defaultRewrite)
        XCTAssertFalse(shortcuts.isDefault(.restore))
        XCTAssertTrue(shortcuts.isDefault(.rewrite))
    }
}
