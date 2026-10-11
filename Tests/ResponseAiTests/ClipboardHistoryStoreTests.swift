import AppKit
import XCTest
@testable import ResponseAi

final class ClipboardHistoryStoreTests: XCTestCase {
    @MainActor
    func testMissingTargetDoesNotChangeHistoryOrClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        pasteboard.setString("original", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }
        let before = store.items
        let count = pasteboard.changeCount
        let pasted = await store.pasteItem(id: try XCTUnwrap(store.items.first?.id), target: nil)
        XCTAssertFalse(pasted)
        XCTAssertEqual(store.items, before)
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    @MainActor
    func testHistoryPreservesExactOriginalText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = "  first\r\nsecond\n  "
        pasteboard.setString(original, forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }
        XCTAssertEqual(store.items.first?.text, original)
    }

    @MainActor
    func testConcealedClipboardIsNotCaptured() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        pasteboard.setString("do-not-store", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor
    func testClearCannotBeUndoneByPendingPersistence() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        pasteboard.setString("ephemeral", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }
        store.clear()
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(store.items.isEmpty)
        let reloaded = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    @MainActor
    func testRestartingMonitorAndRelaunchKeepHistory() throws {
        let (pasteboard, defaults, cleanup) = try makeIsolatedState()
        defer { cleanup() }
        pasteboard.setString("first", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        store.stopMonitoring()
        store.startMonitoring()
        store.stopMonitoring()
        XCTAssertEqual(store.items.map(\.text), ["first"])

        // Next launch (or a second instance during "再起動") reads the same history.
        pasteboard.clearContents()
        let relaunched = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        relaunched.startMonitoring()
        defer { relaunched.stopMonitoring() }
        XCTAssertEqual(relaunched.items.map(\.text), ["first"])
    }

    @MainActor
    func testSecondStartKeepsSingleMonitor() async throws {
        let (pasteboard, defaults, cleanup) = try makeIsolatedState()
        defer { cleanup() }
        pasteboard.setString("first", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        store.startMonitoring()
        XCTAssertTrue(store.isMonitoring)
        store.stopMonitoring()
        XCTAssertFalse(store.isMonitoring)

        // A leaked second timer would still capture this.
        pasteboard.clearContents()
        pasteboard.setString("after stop", forType: .string)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(store.items.map(\.text), ["first"])
    }

    @MainActor
    func testPollingCapturesNewCopies() async throws {
        let (pasteboard, defaults, cleanup) = try makeIsolatedState()
        defer { cleanup() }
        pasteboard.setString("first", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(store.items.map(\.text), ["second", "first"])
    }

    @MainActor
    func testTurningHistoryOffClearsAndSameValueDoesNot() throws {
        let (pasteboard, defaults, cleanup) = try makeIsolatedState()
        defer { cleanup() }
        pasteboard.setString("first", forType: .string)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        store.startMonitoring()
        defer { store.stopMonitoring() }

        store.isEnabled = true
        XCTAssertEqual(store.items.count, 1, "re-saving an unchanged setting must not touch history")

        store.isEnabled = false
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults).items.isEmpty)
    }

    @MainActor
    func testUnreadableSavedHistoryIsKeptAsBackup() throws {
        let (pasteboard, defaults, cleanup) = try makeIsolatedState()
        defer { cleanup() }
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "clipboardHistory.items.v1")
        let store = ClipboardHistoryStore(pasteboard: pasteboard, defaults: defaults)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "clipboardHistory.items.v1.unreadable"), garbage)
    }

    @MainActor
    private func makeIsolatedState() throws -> (NSPasteboard, UserDefaults, () -> Void) {
        let pasteboard = NSPasteboard.withUniqueName()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (pasteboard, defaults, {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        })
    }
}
