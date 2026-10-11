import Carbon
import XCTest
@testable import ResAICore

final class ShortcutValidationTests: XCTestCase {
    private let shortcuts = AppShortcuts.defaults
    private let usLayout = KeyboardLayout.installed(
        id: "com.apple.keylayout.US",
        keyboardType: KeyboardLayout.keyboardType(physicalLayout: Int(kKeyboardANSI)) ?? 40
    )

    private func key(_ keyCode: Int, _ modifiers: ShortcutModifiers) -> ShortcutTrigger {
        .key(HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    // MARK: Rejections: only duplicates and keys that cannot be recorded

    func testAcceptsAnyCombinationForEveryAction() {
        let accepted: [ShortcutTrigger] = [
            key(kVK_ANSI_R, [.command, .option]),
            key(kVK_ANSI_1, [.control, .shift]),
            key(kVK_ANSI_Slash, [.command, .control, .option, .shift]),
            key(kVK_LeftArrow, [.command, .control]),
            key(kVK_ANSI_J, []),
            key(kVK_Space, []),
            key(kVK_F13, []),
            key(kVK_Escape, []),
            key(kVK_ANSI_J, [.shift]),
            key(kVK_ANSI_1, [.shift]),
            key(kVK_ANSI_C, [.command]),
            key(kVK_Space, [.command]),
            .modifierChord([.command]),
            .modifierChord([.control]),
            .modifierChord([.function]),
            .modifierChord([.command, .shift]),
            .fnCommand
        ]
        let empty = AppShortcuts(
            rewrite: key(kVK_F1, [.control, .option, .command]),
            restore: key(kVK_F2, [.control, .option, .command]),
            formFill: key(kVK_F3, [.control, .option, .command]),
            quickMenu: key(kVK_F4, [.control, .option, .command]),
            voiceTrigger: key(kVK_F5, [.control, .option, .command])
        )
        for trigger in accepted {
            for action in ShortcutAction.allCases {
                XCTAssertNil(empty.validationError(for: trigger, action: action), "\(action) \(trigger.displayName)")
            }
        }
    }

    func testRejectsDuplicatesAcrossActions() {
        XCTAssertEqual(
            shortcuts.validationError(for: AppShortcuts.defaultRestore, action: .rewrite),
            .duplicate(.restore)
        )
        XCTAssertEqual(
            shortcuts.validationError(for: AppShortcuts.defaultVoiceTrigger, action: .quickMenu),
            .duplicate(.voice)
        )
        XCTAssertEqual(
            shortcuts.validationError(for: AppShortcuts.defaultRewrite, action: .voice),
            .duplicate(.rewrite)
        )
        var withChord = shortcuts
        withChord.set(.modifierChord([.control]), for: .restore)
        XCTAssertEqual(
            withChord.validationError(for: .modifierChord([.control]), action: .formFill),
            .duplicate(.restore)
        )
        // Re-recording an action's own shortcut is not a conflict.
        XCTAssertNil(shortcuts.validationError(for: AppShortcuts.defaultRewrite, action: .rewrite))
    }

    func testRejectsKeysThatCannotBeRecorded() {
        XCTAssertEqual(shortcuts.validationError(for: .modifierChord([]), action: .rewrite), .nothingPressed)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_Command, [.shift]), action: .rewrite), .unsupportedKey)
        XCTAssertEqual(shortcuts.validationError(for: key(0x80, []), action: .voice), .unsupportedKey)
        XCTAssertEqual(shortcuts.validationError(for: key(kVK_ANSI_J, [.function, .command]), action: .rewrite), .unsupportedKey)
    }

    func testErrorsExplainTheReason() {
        let errors: [ShortcutValidationError] = [.nothingPressed, .unsupportedKey, .duplicate(.restore)]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        XCTAssertEqual(ShortcutValidationError.duplicate(.restore).errorDescription, "「復元」で使用中です。")
    }

    // MARK: Warnings

    func testWarnsAboutKeysWithoutModifier() throws {
        let layout = try XCTUnwrap(usLayout)
        XCTAssertEqual(key(kVK_ANSI_J, []).warning(layout: layout), .typesCharacter("J"))
        XCTAssertEqual(key(kVK_ANSI_1, []).warning(layout: layout), .typesCharacter("1"))
        XCTAssertEqual(key(kVK_F5, []).warning(layout: layout), .replacesKey("F5"))
        XCTAssertEqual(key(kVK_Space, []).warning(layout: layout), .replacesKey("Space"))
        XCTAssertEqual(key(kVK_Escape, []).warning(layout: layout), .replacesKey("⎋"))
    }

    func testWarnsAboutShiftOnly() throws {
        let layout = try XCTUnwrap(usLayout)
        XCTAssertEqual(key(kVK_ANSI_J, [.shift]).warning(layout: layout), .uppercase("J"))
        XCTAssertEqual(key(kVK_ANSI_1, [.shift]).warning(layout: layout), .shiftedCharacter("⇧ + 1"))
        XCTAssertEqual(key(kVK_LeftArrow, [.shift]).warning(layout: layout), .replacesKey("⇧ + ←"))
        // Without a layout the US letter names are used.
        XCTAssertEqual(key(kVK_ANSI_K, [.shift]).warning(layout: nil), .uppercase("K"))
    }

    func testWarnsAboutEveryReservedSystemShortcut() {
        for reserved in ReservedShortcut.all {
            XCTAssertEqual(
                ShortcutTrigger.key(reserved.shortcut).warning(layout: nil),
                .reserved(reserved.name),
                "\(reserved.name) \(reserved.shortcut)"
            )
        }
    }

    func testWarnsAboutModifierOnly() {
        XCTAssertEqual(ShortcutTrigger.modifierChord([.command]).warning(layout: nil), .modifierOnly("⌘"))
        XCTAssertEqual(ShortcutTrigger.fnCommand.warning(layout: nil), .modifierOnly("fn + ⌘"))
    }

    func testNoWarningForOrdinaryCombinationsAndDefaults() {
        XCTAssertNil(key(kVK_ANSI_R, [.command, .option]).warning(layout: nil))
        XCTAssertNil(key(kVK_ANSI_J, [.shift, .option]).warning(layout: nil))
        XCTAssertNil(key(kVK_ANSI_J, [.command]).warning(layout: nil))
        for action in ShortcutAction.allCases {
            XCTAssertNil(AppShortcuts.defaults.trigger(for: action).warning(layout: nil), action.rawValue)
        }
    }

    func testWarningTextsAskAndThenDescribeTheLoss() {
        let warnings: [ShortcutWarning] = [
            .typesCharacter("J"), .replacesKey("F5"), .uppercase("J"),
            .shiftedCharacter("⇧ + 1"), .reserved("コピー"), .modifierOnly("⌘")
        ]
        for warning in warnings {
            XCTAssertTrue(warning.confirmationMessage.hasSuffix("登録しますか？"), "\(warning)")
            XCTAssertFalse(warning.note.isEmpty)
        }
        XCTAssertEqual(ShortcutWarning.typesCharacter("J").note, "「J」が入力できなくなっています")
        XCTAssertEqual(
            ShortcutWarning.reserved("コピー").confirmationMessage,
            "この組み合わせにすると macOS・定番のショートカット（コピー）が使えなくなります。登録しますか？"
        )
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
        for action in ShortcutAction.allCases {
            XCTAssertFalse(reserved.contains(AppShortcuts.defaults.trigger(for: action)), action.rawValue)
        }
    }

    func testSetStoresTriggerForEveryAction() {
        var shortcuts = AppShortcuts.defaults
        let optionR = key(kVK_ANSI_R, [.command, .option])

        shortcuts.set(optionR, for: .restore)
        shortcuts.set(.fnCommand, for: .voice)
        shortcuts.set(.modifierChord([.command, .shift]), for: .rewrite)

        XCTAssertEqual(shortcuts.restore, optionR)
        XCTAssertEqual(shortcuts.voiceTrigger, .fnCommand)
        XCTAssertEqual(shortcuts.rewrite, .modifierChord([.command, .shift]))
        XCTAssertFalse(shortcuts.isDefault(.restore))
        XCTAssertFalse(shortcuts.isDefault(.rewrite))
        XCTAssertTrue(shortcuts.isDefault(.formFill))
    }
}
