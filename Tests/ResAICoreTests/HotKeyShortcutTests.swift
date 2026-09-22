import XCTest
@testable import ResAICore

final class HotKeyShortcutTests: XCTestCase {
    func testDefaultShortcutsMatchPrimaryActions() {
        let shortcuts = AppShortcuts.defaults

        XCTAssertEqual(shortcuts.rewrite.displayName, "⌘ + ⇧ + J")
        XCTAssertEqual(shortcuts.restore.displayName, "⌘ + ⇧ + U")
        XCTAssertEqual(shortcuts.formFill.displayName, "⌘ + ⇧ + K")
        XCTAssertEqual(shortcuts.quickMenu.displayName, "⌘ + ⇧ + V")
        XCTAssertEqual(shortcuts.voiceTrigger, .commandShift(.space))
        XCTAssertEqual(shortcuts.voiceTrigger.displayName, "⌘ + ⇧ + Space")
        XCTAssertEqual(VoiceTrigger.fnCommand.displayName, "fn + ⌘")
        XCTAssertFalse(shortcuts.hasConflicts)
    }

    func testSanitizedShortcutsRemoveConflicts() {
        let shortcuts = AppShortcuts(
            rewrite: HotKeyShortcut(key: .j),
            restore: HotKeyShortcut(key: .j),
            formFill: HotKeyShortcut(key: .j),
            quickMenu: HotKeyShortcut(key: .j)
        ).sanitized()

        XCTAssertEqual(shortcuts.rewrite.key, .j)
        XCTAssertEqual(shortcuts.restore.key, .u)
        XCTAssertEqual(shortcuts.formFill.key, .k)
        XCTAssertEqual(shortcuts.quickMenu.key, .v)
        XCTAssertFalse(shortcuts.hasConflicts)
    }

    func testShortcutDefaultsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HotKeyShortcutTests"))
        defaults.removePersistentDomain(forName: "HotKeyShortcutTests")

        let shortcuts = AppShortcuts(
            rewrite: HotKeyShortcut(key: .r),
            restore: HotKeyShortcut(key: .y),
            formFill: HotKeyShortcut(key: .f),
            quickMenu: HotKeyShortcut(key: .v)
        )
        shortcuts.save(defaults: defaults)

        XCTAssertEqual(AppShortcuts.load(defaults: defaults), shortcuts)
    }

    func testOlderShortcutPayloadGetsQuickMenuDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HotKeyShortcutMigrationTests"))
        defaults.removePersistentDomain(forName: "HotKeyShortcutMigrationTests")
        defaults.set(
            Data("""
            {
              "rewrite": { "key": "r" },
              "restore": { "key": "y" },
              "formFill": { "key": "f" }
            }
            """.utf8),
            forKey: AppShortcuts.DefaultsKey.shortcuts
        )

        let shortcuts = AppShortcuts.load(defaults: defaults)

        XCTAssertEqual(shortcuts.rewrite.key, .r)
        XCTAssertEqual(shortcuts.restore.key, .y)
        XCTAssertEqual(shortcuts.formFill.key, .f)
        XCTAssertEqual(shortcuts.quickMenu.key, .v)
    }

    func testVoiceTriggerRoundTripsThroughJSON() throws {
        let shortcuts = AppShortcuts(
            rewrite: HotKeyShortcut(key: .j),
            restore: HotKeyShortcut(key: .u),
            formFill: HotKeyShortcut(key: .k),
            quickMenu: HotKeyShortcut(key: .v),
            voice: HotKeyShortcut(key: .space),
            voiceTrigger: .fnCommand
        )

        let encoded = try JSONEncoder().encode(shortcuts)
        let decoded = try JSONDecoder().decode(AppShortcuts.self, from: encoded)

        XCTAssertEqual(decoded.voiceTrigger, .fnCommand)
        XCTAssertEqual(decoded.voice.key, .space)

        let letter = AppShortcuts(voiceTrigger: .commandShift(.a))
        let letterDecoded = try JSONDecoder().decode(
            AppShortcuts.self,
            from: try JSONEncoder().encode(letter)
        )
        XCTAssertEqual(letterDecoded.voiceTrigger, .commandShift(.a))
        XCTAssertEqual(letterDecoded.voice.key, .a)
    }

    func testLegacyJSONWithoutVoiceTriggerDecodesToCommandShiftSpace() throws {
        let json = Data("""
            {
              "rewrite": { "key": "j" },
              "restore": { "key": "u" },
              "formFill": { "key": "k" },
              "quickMenu": { "key": "v" },
              "voice": { "key": "space" }
            }
            """.utf8)

        let decoded = try JSONDecoder().decode(AppShortcuts.self, from: json)

        XCTAssertEqual(decoded.voiceTrigger, .commandShift(.space))
        XCTAssertEqual(decoded.voice.key, .space)
    }

    func testHasConflictsIgnoresVoiceWhenFnCommand() {
        let conflictingLetter = AppShortcuts(
            rewrite: HotKeyShortcut(key: .space),
            restore: HotKeyShortcut(key: .u),
            formFill: HotKeyShortcut(key: .k),
            quickMenu: HotKeyShortcut(key: .v),
            voice: HotKeyShortcut(key: .space),
            voiceTrigger: .commandShift(.space)
        )
        XCTAssertTrue(conflictingLetter.hasConflicts)

        let fnCommand = AppShortcuts(
            rewrite: HotKeyShortcut(key: .space),
            restore: HotKeyShortcut(key: .u),
            formFill: HotKeyShortcut(key: .k),
            quickMenu: HotKeyShortcut(key: .v),
            voice: HotKeyShortcut(key: .space),
            voiceTrigger: .fnCommand
        )
        XCTAssertFalse(fnCommand.hasConflicts)
        XCTAssertEqual(fnCommand.sanitized().voice.key, .space)
        XCTAssertEqual(fnCommand.sanitized().voiceTrigger, .fnCommand)
    }
}
