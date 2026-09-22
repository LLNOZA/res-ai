import CoreGraphics
import Foundation

/// Shared background `CFRunLoop` for `CGEventTap` sources.
///
/// Taps registered on the main run loop are disabled by macOS when the main thread stalls
/// (~1 s). This loop lives on `ai.res.resai.event-tap` so tap callbacks keep firing.
///
/// `runLoop` is published by the helper thread and refreshed lazily if its bounded
/// startup wait expires. `dummyPort` / `dummySource` keep the loop from exiting. Add/remove of tap sources
/// always bounce onto this run loop via `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`
/// (and wait) so they are safe from any thread except this one — calling add/remove
/// from the tap callback itself would deadlock on the wait, so callers must not.
final class EventTapRunLoop: @unchecked Sendable {
    static let shared = EventTapRunLoop()

    private let lock = NSLock()
    private let thread: Thread
    private var dummyPort: CFMachPort?
    private var dummySource: CFRunLoopSource?
    private let startupBox: StartupBox
    private var _runLoop: CFRunLoop?

    var runLoop: CFRunLoop? {
        lock.lock()
        if _runLoop == nil, let snapshot = startupBox.snapshot() {
            // The first bounded wait may expire while Thread is still starting.
            // Refresh lazily so the helper becomes usable once it signals ready.
            _runLoop = snapshot.runLoop
            dummyPort = snapshot.port
            dummySource = snapshot.source
        }
        defer { lock.unlock() }
        return _runLoop
    }

    var isAvailable: Bool {
        runLoop != nil
    }

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let box = StartupBox()

        let thread = Thread {
            guard let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil) else {
                ready.signal()
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                ready.signal()
                return
            }

            guard let loop = CFRunLoopGetCurrent() else {
                CFMachPortInvalidate(port)
                ready.signal()
                return
            }
            CFRunLoopAddSource(loop, source, .commonModes)
            box.set(port: port, source: source, runLoop: loop)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "ai.res.resai.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Initialization can happen from the main actor during the first shortcut
        // registration. Never wait forever if the helper thread cannot start.
        _ = ready.wait(timeout: .now() + 2.0)
        let snapshot = box.snapshot()
        self.thread = thread
        self.startupBox = box
        self.dummyPort = snapshot?.port
        self.dummySource = snapshot?.source
        self._runLoop = snapshot?.runLoop
    }

    @discardableResult
    func add(_ source: CFRunLoopSource) -> Bool {
        performAndWait { loop in
            CFRunLoopAddSource(loop, source, .commonModes)
        }
    }

    /// Removes a source and runs `completion` on the tap thread after the source has
    /// been detached. The completion is deliberately part of this operation: callers
    /// use it to release the retained object passed to `CGEvent.tapCreate`. If the
    /// thread is temporarily late, the operation still completes later and the
    /// retained object cannot be released while a callback can reference it.
    @discardableResult
    func remove(
        _ source: CFRunLoopSource,
        beforeRemove: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) -> Bool {
        performAndWait { loop in
            beforeRemove?()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            completion?()
        }
    }

    /// Performs work on the tap thread with a finite wait. A dead or suspended
    /// event-tap thread must never block the main actor indefinitely during a
    /// settings change or app shutdown. The block remains queued when the timeout
    /// expires and will run if the run loop resumes.
    @discardableResult
    func performAndWait(
        timeout: TimeInterval = 1.0,
        _ work: @escaping (CFRunLoop) -> Void
    ) -> Bool {
        guard let loop = runLoop else {
            return false
        }
        if CFEqual(CFRunLoopGetCurrent(), loop) {
            work(loop)
            return true
        }

        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            work(loop)
            done.signal()
        }
        CFRunLoopWakeUp(loop)
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// Startup state is protected because the bounded initializer wait may expire
/// while the helper thread is still publishing its run loop.
private final class StartupBox: @unchecked Sendable {
    struct Snapshot {
        let port: CFMachPort
        let source: CFRunLoopSource
        let runLoop: CFRunLoop
    }

    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    func set(port: CFMachPort, source: CFRunLoopSource, runLoop: CFRunLoop) {
        lock.lock()
        self.port = port
        self.source = source
        self.runLoop = runLoop
        lock.unlock()
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let port, let source, let runLoop else {
            return nil
        }
        return Snapshot(port: port, source: source, runLoop: runLoop)
    }
}
