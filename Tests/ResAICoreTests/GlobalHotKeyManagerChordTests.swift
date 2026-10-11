import Carbon
import CoreGraphics
import XCTest
@testable import ResAICore

/// Drives `GlobalHotKeyManager.handleModifierChord` with synthesized events,
/// without installing an event tap.
final class GlobalHotKeyManagerChordTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]

        func add(_ name: String) {
            lock.lock()
            values[name, default: 0] += 1
            lock.unlock()
        }

        subscript(_ name: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return values[name, default: 0]
        }
    }

    private func makeManager(_ counts: Counts) -> GlobalHotKeyManager {
        GlobalHotKeyManager(
            callback: { counts.add("press") },
            onRelease: { counts.add("release") },
            onCancel: { counts.add("cancel") }
        )
    }

    private func flags(_ manager: GlobalHotKeyManager, _ flags: CGEventFlags) throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.flags = flags
        _ = manager.handleModifierChord(type: .flagsChanged, event: event)
    }

    private func key(_ manager: GlobalHotKeyManager, _ keyCode: Int, down: Bool) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down))
        _ = manager.handleModifierChord(type: down ? .keyDown : .keyUp, event: event)
    }

    /// Callbacks hop to the main actor through `Task`.
    private func drainMainActor() async {
        for _ in 0..<5 {
            await MainActor.run {}
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testHoldStyleDeliversCancelOnceWhenOrdinaryKeyArrives() async throws {
        let counts = Counts()
        let manager = makeManager(counts)
        manager.modifierChordStyle = .hold
        manager.prepareModifierChord([.maskCommand, .maskShift])

        // ⌘⇧ held, then T (twice), then everything up.
        try flags(manager, [.maskCommand])
        try flags(manager, [.maskCommand, .maskShift])
        try key(manager, kVK_ANSI_T, down: true)
        try key(manager, kVK_ANSI_T, down: false)
        try key(manager, kVK_ANSI_T, down: true)
        try key(manager, kVK_ANSI_T, down: false)
        try flags(manager, [.maskCommand])
        try flags(manager, [])
        await drainMainActor()

        XCTAssertEqual(counts["press"], 1)
        XCTAssertEqual(counts["cancel"], 1)
        XCTAssertEqual(counts["release"], 0)
    }

    func testHoldStyleReleasesWhenNothingElseIsPressed() async throws {
        let counts = Counts()
        let manager = makeManager(counts)
        manager.modifierChordStyle = .hold
        manager.prepareModifierChord([.maskSecondaryFn, .maskCommand])

        try flags(manager, [.maskSecondaryFn, .maskCommand])
        try flags(manager, [])
        await drainMainActor()

        XCTAssertEqual(counts["press"], 1)
        XCTAssertEqual(counts["release"], 1)
        XCTAssertEqual(counts["cancel"], 0)
    }

    func testTapStyleFiresOnReleaseOnlyWhenPressedAlone() async throws {
        let counts = Counts()
        let manager = makeManager(counts)
        manager.prepareModifierChord([.maskCommand, .maskShift])

        try flags(manager, [.maskCommand, .maskShift])
        await drainMainActor()
        XCTAssertEqual(counts["press"], 0, "nothing fires while the chord is still held")

        try flags(manager, [])
        await drainMainActor()
        XCTAssertEqual(counts["press"], 1)

        // ⌘⇧T: nothing.
        try flags(manager, [.maskCommand, .maskShift])
        try key(manager, kVK_ANSI_T, down: true)
        try key(manager, kVK_ANSI_T, down: false)
        try flags(manager, [])
        await drainMainActor()

        XCTAssertEqual(counts["press"], 1)
        XCTAssertEqual(counts["release"], 0)
        XCTAssertEqual(counts["cancel"], 0)
    }

    func testTapStyleIgnoresClickWhileHeld() async throws {
        let counts = Counts()
        let manager = makeManager(counts)
        manager.prepareModifierChord([.maskCommand])

        try flags(manager, [.maskCommand])
        let click = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        _ = manager.handleModifierChord(type: .leftMouseDown, event: click)
        try flags(manager, [])
        await drainMainActor()

        XCTAssertEqual(counts["press"], 0)
    }
}
