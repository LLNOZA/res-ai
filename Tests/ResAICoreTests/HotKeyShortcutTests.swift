import Carbon
import XCTest
@testable import ResAICore

final class HotKeyShortcutTests: XCTestCase {
    private let usLayout = KeyboardLayout.installed(
        id: "com.apple.keylayout.US",
        keyboardType: KeyboardLayout.keyboardType(physicalLayout: Int(kKeyboardANSI)) ?? 40
    )

    func testDefaultShortcutsMatchPrimaryActions() throws {
        let shortcuts = AppShortcuts.defaults
        let layout = try XCTUnwrap(usLayout)

        XCTAssertEqual(shortcuts.rewrite.displayName(layout: layout), "⌘ + ⇧ + J")
        XCTAssertEqual(shortcuts.restore.displayName(layout: layout), "⌘ + ⇧ + U")
        XCTAssertEqual(shortcuts.formFill.displayName(layout: layout), "⌘ + ⇧ + K")
        XCTAssertEqual(shortcuts.quickMenu.displayName(layout: layout), "⌘ + ⇧ + V")
        XCTAssertEqual(shortcuts.voiceTrigger, .key(.commandShift(kVK_Space)))
        XCTAssertEqual(shortcuts.voiceTrigger.displayName, "⌘ + ⇧ + Space")
        XCTAssertEqual(ShortcutTrigger.fnCommand.displayName, "fn + ⌘")
        XCTAssertFalse(shortcuts.hasConflicts)
    }

    func testSanitizedShortcutsRemoveConflicts() {
        let j = HotKeyShortcut.commandShift(kVK_ANSI_J)
        let shortcuts = AppShortcuts(rewrite: j, restore: j, formFill: j, quickMenu: j).sanitized()

        XCTAssertEqual(shortcuts.rewrite, .commandShift(kVK_ANSI_J))
        XCTAssertEqual(shortcuts.restore, .commandShift(kVK_ANSI_U))
        XCTAssertEqual(shortcuts.formFill, .commandShift(kVK_ANSI_K))
        XCTAssertEqual(shortcuts.quickMenu, .commandShift(kVK_ANSI_V))
        XCTAssertFalse(shortcuts.hasConflicts)
    }

    func testSanitizedMovesCollidingVoiceKeyToDefaultOrChord() {
        let space = HotKeyShortcut.commandShift(kVK_Space)
        let shortcuts = AppShortcuts(rewrite: space, voiceTrigger: .key(space)).sanitized()

        // ⌘⇧Space is taken by rewrite, so voice falls back to a chord that cannot collide.
        XCTAssertEqual(shortcuts.rewrite, space)
        XCTAssertEqual(shortcuts.voiceTrigger, .fnCommand)
    }

    func testSanitizedKeepsChordVoiceAndRepairsUnregistrableShapes() {
        let shortcuts = AppShortcuts(
            rewrite: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: []),
            restore: HotKeyShortcut(keyCode: UInt32(kVK_Command), modifiers: [.command]),
            voiceTrigger: .modifierChord([.command])
        ).sanitized()

        XCTAssertEqual(shortcuts.rewrite, AppShortcuts.defaultRewrite)
        XCTAssertEqual(shortcuts.restore, AppShortcuts.defaultRestore)
        XCTAssertEqual(shortcuts.voiceTrigger, .fnCommand)
    }

    // MARK: Persistence

    func testShortcutDefaultsRoundTrip() throws {
        let defaults = try freshDefaults("HotKeyShortcutTests")

        let shortcuts = AppShortcuts(
            rewrite: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .option]),
            restore: HotKeyShortcut(keyCode: UInt32(kVK_F5), modifiers: []),
            formFill: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: [.control, .shift]),
            quickMenu: HotKeyShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: [.command, .control]),
            voiceTrigger: .modifierChord([.function, .option, .command])
        )
        shortcuts.save(defaults: defaults)

        XCTAssertEqual(AppShortcuts.load(defaults: defaults), shortcuts)
    }

    func testSavedPayloadUsesReadableVersionedFormat() throws {
        let data = try JSONEncoder().encode(AppShortcuts(voiceTrigger: .fnCommand))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, 2)
        let rewrite = try XCTUnwrap(object["rewrite"] as? [String: Any])
        XCTAssertEqual(rewrite["keyCode"] as? Int, kVK_ANSI_J)
        XCTAssertEqual(rewrite["modifiers"] as? [String], ["command", "shift"])
        let voice = try XCTUnwrap(object["voice"] as? [String: Any])
        XCTAssertEqual(voice["type"] as? String, "modifiers")
        XCTAssertEqual(voice["modifiers"] as? [String], ["function", "command"])
    }

    func testSavingWritesV2AndLeavesLegacyPayloadAlone() throws {
        let defaults = try freshDefaults("HotKeyShortcutLegacyKeep")
        let legacy = Data(#"{"rewrite":{"key":"r"}}"#.utf8)
        defaults.set(legacy, forKey: AppShortcuts.DefaultsKey.legacyShortcuts)

        AppShortcuts.defaults.save(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: AppShortcuts.DefaultsKey.legacyShortcuts), legacy)
        XCTAssertNotNil(defaults.data(forKey: AppShortcuts.DefaultsKey.shortcuts))
        XCTAssertEqual(AppShortcuts.load(defaults: defaults), .defaults)
    }

    // MARK: Migration from shortcuts.v1

    func testLegacyCommandShiftLettersMigrateToSameShortcuts() throws {
        let defaults = try freshDefaults("HotKeyShortcutMigrationLetters")
        defaults.set(Data("""
            {
              "rewrite": { "key": "r" },
              "restore": { "key": "y" },
              "formFill": { "key": "f" },
              "quickMenu": { "key": "m" },
              "voice": { "key": "a" },
              "voiceTrigger": { "commandShift": { "_0": "a" } }
            }
            """.utf8), forKey: AppShortcuts.DefaultsKey.legacyShortcuts)

        let shortcuts = AppShortcuts.load(defaults: defaults)

        XCTAssertEqual(shortcuts.rewrite, .commandShift(kVK_ANSI_R))
        XCTAssertEqual(shortcuts.restore, .commandShift(kVK_ANSI_Y))
        XCTAssertEqual(shortcuts.formFill, .commandShift(kVK_ANSI_F))
        XCTAssertEqual(shortcuts.quickMenu, .commandShift(kVK_ANSI_M))
        XCTAssertEqual(shortcuts.voiceTrigger, .key(.commandShift(kVK_ANSI_A)))
        XCTAssertEqual(shortcuts.voiceTrigger.keyShortcut?.displayName(layout: usLayout), "⌘ + ⇧ + A")
    }

    func testLegacyFnCommandMigratesToModifierChord() throws {
        let defaults = try freshDefaults("HotKeyShortcutMigrationFn")
        defaults.set(Data("""
            {
              "rewrite": { "key": "j" },
              "restore": { "key": "u" },
              "formFill": { "key": "k" },
              "quickMenu": { "key": "v" },
              "voice": { "key": "space" },
              "voiceTrigger": { "fnCommand": {} }
            }
            """.utf8), forKey: AppShortcuts.DefaultsKey.legacyShortcuts)

        let shortcuts = AppShortcuts.load(defaults: defaults)

        XCTAssertEqual(shortcuts.voiceTrigger, .modifierChord([.function, .command]))
        XCTAssertEqual(shortcuts.voiceTrigger.displayName, "fn + ⌘")
        XCTAssertEqual(shortcuts.rewrite, AppShortcuts.defaultRewrite)
    }

    func testLegacyCommandSpaceMigratesUnchangedEvenThoughItIsReserved() throws {
        let defaults = try freshDefaults("HotKeyShortcutMigrationSpace")
        defaults.set(Data("""
            {
              "rewrite": { "key": "j" },
              "restore": { "key": "u" },
              "formFill": { "key": "k" },
              "quickMenu": { "key": "v" },
              "voice": { "key": "space" },
              "voiceTrigger": { "commandSpace": {} }
            }
            """.utf8), forKey: AppShortcuts.DefaultsKey.legacyShortcuts)

        let shortcuts = AppShortcuts.load(defaults: defaults)

        XCTAssertEqual(
            shortcuts.voiceTrigger,
            .key(HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: [.command]))
        )
        XCTAssertEqual(shortcuts.voiceTrigger.displayName, "⌘ + Space")
    }

    func testOlderLegacyPayloadWithoutQuickMenuOrVoiceGetsDefaults() throws {
        let defaults = try freshDefaults("HotKeyShortcutMigrationOld")
        defaults.set(Data("""
            {
              "rewrite": { "key": "r" },
              "restore": { "key": "y" },
              "formFill": { "key": "f" }
            }
            """.utf8), forKey: AppShortcuts.DefaultsKey.legacyShortcuts)

        let shortcuts = AppShortcuts.load(defaults: defaults)

        XCTAssertEqual(shortcuts.rewrite, .commandShift(kVK_ANSI_R))
        XCTAssertEqual(shortcuts.restore, .commandShift(kVK_ANSI_Y))
        XCTAssertEqual(shortcuts.formFill, .commandShift(kVK_ANSI_F))
        XCTAssertEqual(shortcuts.quickMenu, .commandShift(kVK_ANSI_V))
        XCTAssertEqual(shortcuts.voiceTrigger, AppShortcuts.defaultVoiceTrigger)
    }

    func testBrokenPayloadsFallBackToDefaults() throws {
        let broken: [(String, String)] = [
            (AppShortcuts.DefaultsKey.shortcuts, "not json"),
            (AppShortcuts.DefaultsKey.shortcuts, #"{"version":3,"rewrite":{"keyCode":38,"modifiers":["command"]}}"#),
            (AppShortcuts.DefaultsKey.shortcuts, #"{"version":2,"rewrite":{"keyCode":38,"modifiers":["hyper"]}}"#),
            (AppShortcuts.DefaultsKey.shortcuts, #"{"version":2,"voice":{"type":"pedal","modifiers":[]}}"#),
            (AppShortcuts.DefaultsKey.legacyShortcuts, #"{"rewrite":{"key":"zz"}}"#),
            (AppShortcuts.DefaultsKey.legacyShortcuts, "[]")
        ]
        for (index, (key, payload)) in broken.enumerated() {
            let defaults = try freshDefaults("HotKeyShortcutBroken\(index)")
            defaults.set(Data(payload.utf8), forKey: key)

            XCTAssertEqual(AppShortcuts.load(defaults: defaults), .defaults, payload)
        }
    }

    func testUnreadableV2DoesNotFallBackToStaleLegacy() throws {
        let defaults = try freshDefaults("HotKeyShortcutBrokenV2")
        defaults.set(Data(#"{"rewrite":{"key":"r"}}"#.utf8), forKey: AppShortcuts.DefaultsKey.legacyShortcuts)
        defaults.set(Data("garbage".utf8), forKey: AppShortcuts.DefaultsKey.shortcuts)

        XCTAssertEqual(AppShortcuts.load(defaults: defaults), .defaults)
    }

    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
