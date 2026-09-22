import AppKit
import Foundation

/// Watches for user keypresses and clicks after a voice insertion so a keyboard
/// cleanup swap cannot eat text the user typed in the meantime.
public final class KeyboardSwapGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var typed = false
    private var paused = false
    private var failClosed = false
    private var firstTrigger: String?
    private var monitor: Any?
    private var localMonitor: Any?

    /// Debug description of the first real user event seen since `start()`.
    public var triggerDescription: String {
        lock.lock()
        defer { lock.unlock() }
        if failClosed { return "monitor unavailable" }
        return firstTrigger ?? "none"
    }

    public init() {}

    deinit {
        removeMonitor()
    }

    public var userTypedSinceInsertion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return typed || failClosed
    }

    public func start() {
        stop()
        lock.lock()
        typed = false
        paused = false
        failClosed = false
        firstTrigger = nil
        lock.unlock()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.note(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.note(event)
            return event
        }
        if monitor == nil && localMonitor == nil {
            lock.lock()
            failClosed = true
            lock.unlock()
        }
    }

    /// Kept for source compatibility with callers around the synthesized keyboard swap. The
    /// monitor itself filters tagged synthetic events; pausing must never hide real user input.
    public func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        paused = false
        lock.unlock()
    }

    public func stop() {
        removeMonitor()
        lock.lock()
        paused = false
        lock.unlock()
    }

    private func noteUserEvent(_ description: String) {
        lock.lock()
        defer { lock.unlock() }
        if firstTrigger == nil { firstTrigger = description }
        typed = true
    }

    private func note(_ event: NSEvent) {
        // Our own ⌘V / ⇧← / focus clicks are tagged; only real user input counts. This check is
        // deliberately performed while the guard is "paused" so physical input is still seen
        // during the vulnerable selection-to-paste window.
        guard !SyntheticEventMarker.isSynthetic(event.cgEvent) else { return }
        let description = event.type == .keyDown
            ? "keyDown code=\(event.keyCode) flags=\(event.modifierFlags.rawValue)"
            : "leftMouseDown"
        noteUserEvent(description)
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
