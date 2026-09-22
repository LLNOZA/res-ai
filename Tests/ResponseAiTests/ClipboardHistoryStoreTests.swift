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
}
