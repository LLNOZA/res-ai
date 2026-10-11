import Carbon
import XCTest
@testable import ResAICore

final class KeyCodeNamesTests: XCTestCase {
    private func layout(_ physical: Int32) throws -> KeyboardLayout {
        let type = try XCTUnwrap(KeyboardLayout.keyboardType(physicalLayout: Int(physical)))
        return try XCTUnwrap(KeyboardLayout.installed(id: "com.apple.keylayout.US", keyboardType: type))
    }

    func testUSKeyboardNames() throws {
        let us = try layout(Int32(kKeyboardANSI))

        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_J), layout: us), "J")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_1), layout: us), "1")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_LeftBracket), layout: us), "[")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Equal), layout: us), "=")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Quote), layout: us), "'")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Slash), layout: us), "/")
    }

    func testJISKeyboardNamesFollowPrintedKeys() throws {
        let jis = try layout(Int32(kKeyboardJIS))

        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_J), layout: jis), "J")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_LeftBracket), layout: jis), "@")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Equal), layout: jis), "^")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Quote), layout: jis), ":")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_JIS_Yen), layout: jis), "¥")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_JIS_Underscore), layout: jis), "_")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_JIS_Eisu), layout: jis), "英数")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_JIS_Kana), layout: jis), "かな")
    }

    func testSpecialKeysDoNotDependOnLayout() {
        for layout in [nil, KeyboardLayout.current] {
            XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_Space), layout: layout), "Space")
            XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_F1), layout: layout), "F1")
            XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_F12), layout: layout), "F12")
            XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_LeftArrow), layout: layout), "←")
            XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_Return), layout: layout), "↩")
        }
    }

    func testFallsBackToANSINamesWithoutLayout() {
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_K), layout: nil), "K")
        XCTAssertEqual(KeyCodeNames.displayName(forKeyCode: UInt32(kVK_ANSI_Keypad1), layout: nil), "テンキー1")
    }

    func testDisplayNameCombinesModifiersInAppOrder() throws {
        let us = try layout(Int32(kKeyboardANSI))
        let shortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: [.shift, .command, .option, .control]
        )

        XCTAssertEqual(shortcut.displayName(layout: us), "⌃ + ⌥ + ⌘ + ⇧ + R")
        XCTAssertEqual(ShortcutTrigger.modifierChord([.command, .function, .option]).displayName, "fn + ⌥ + ⌘")
    }

    func testMenuKeyEquivalents() throws {
        let us = try layout(Int32(kKeyboardANSI))

        XCTAssertEqual(KeyCodeNames.keyEquivalent(forKeyCode: UInt32(kVK_ANSI_J), layout: us), "j")
        XCTAssertEqual(KeyCodeNames.keyEquivalent(forKeyCode: UInt32(kVK_Space), layout: us), " ")
        XCTAssertEqual(KeyCodeNames.keyEquivalent(forKeyCode: UInt32(kVK_F1), layout: us), "\u{F704}")
        XCTAssertEqual(KeyCodeNames.keyEquivalent(forKeyCode: UInt32(kVK_UpArrow), layout: us), "\u{F700}")
        XCTAssertEqual(KeyCodeNames.keyEquivalent(forKeyCode: UInt32(kVK_JIS_Eisu), layout: us), "")
    }
}
