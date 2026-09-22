import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Serializes synthesized HID events (⌘V, ⇧←, focus clicks) and inter-key delays.
///
/// Jobs hop off the main actor so `CGEventTap`s are not starved by `Task.sleep` / event posting.
/// The GCD queue `ai.res.resai.input-synth` is the non-reentrant gate: each job's `Task` may
/// suspend, but the next job is not started until the previous one has fully finished.
public final class InputSynthesizer: @unchecked Sendable {
    public static let shared = InputSynthesizer()

    private let queue = DispatchQueue(label: "ai.res.resai.input-synth")

    private final class RunState<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var child: Task<T, Error>?
        private var cancelled = false
        private var finished = false
        /// Set when the serial queue has begun executing this job. A cancellation before that
        /// point can resume the caller immediately; once set, the caller remains suspended until
        /// the child has stopped so a canceled job cannot mutate input after its parent is idle.
        private var started = false

        func install(continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            self.continuation = continuation
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                finish(.failure(CancellationError()))
            }
        }

        func install(child: Task<T, Error>) {
            lock.lock()
            self.child = child
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                child.cancel()
            }
        }

        /// Claims the queued slot. This closes the race between the queue closure checking
        /// cancellation and installing the child task: cancellation after `begin()` is treated
        /// as cancellation of an active job and must wait for the child result.
        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !finished else {
                return false
            }
            started = true
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let child = self.child
            // A queued job has not posted any input and may fail immediately. An active job must
            // finish its child first; resuming here would let the caller start another job while
            // this one is still unwinding synthesized key/mouse events.
            let shouldFinish = !started && !finished && self.continuation != nil
            lock.unlock()
            child?.cancel()
            if shouldFinish {
                finish(.failure(CancellationError()))
            }
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            let finalResult: Result<T, Error> = cancelled
                ? .failure(CancellationError())
                : result
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: finalResult)
        }
    }

    private init() {}

    /// Runs `body` off the main actor, serialized with other synthesizer jobs.
    /// `sleep` / `sendCommandShortcut` / `sendShiftLeftArrow` / `focusInputByClick` do **not**
    /// re-enter this gate, so they are safe to call from inside `body`.
    public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let state = RunState<T>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                state.install(continuation: continuation)
                queue.async {
                    guard state.begin() else {
                        state.finish(.failure(CancellationError()))
                        return
                    }

                    let child = Task<T, Error> {
                        try await body()
                    }
                    state.install(child: child)
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        let result = await child.result
                        state.finish(result)
                        done.signal()
                    }
                    // This is the serial gate: the next queued job does not begin until the
                    // previous async body has completed or cooperatively cancelled.
                    done.wait()
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }

    @discardableResult
    public func sleep(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    @discardableResult
    public func sleep(milliseconds: UInt64) async -> Bool {
        await sleep(nanoseconds: milliseconds * 1_000_000)
    }

    public func sendCommandShortcut(keyCode: UInt16) async {
        guard !Task.isCancelled else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        postKey(UInt16(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        guard await sleep(nanoseconds: 20_000_000) else {
            postKey(UInt16(kVK_Command), keyDown: false, flags: [], source: source)
            return
        }
        postKey(keyCode, keyDown: true, flags: .maskCommand, source: source)
        guard await sleep(nanoseconds: 20_000_000) else {
            postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
            postKey(UInt16(kVK_Command), keyDown: false, flags: [], source: source)
            return
        }
        postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
        guard await sleep(nanoseconds: 20_000_000) else {
            postKey(UInt16(kVK_Command), keyDown: false, flags: [], source: source)
            return
        }
        postKey(UInt16(kVK_Command), keyDown: false, flags: [], source: source)
    }

    public func sendShiftLeftArrow(times count: Int) async {
        guard count > 0 else {
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let left = UInt16(kVK_LeftArrow)
        let shift = UInt16(kVK_Shift)

        guard !Task.isCancelled else { return }
        postKey(shift, keyDown: true, flags: .maskShift, source: source)
        for _ in 0..<count {
            guard !Task.isCancelled else {
                postKey(shift, keyDown: false, flags: [], source: source)
                return
            }
            postKey(left, keyDown: true, flags: .maskShift, source: source)
            postKey(left, keyDown: false, flags: .maskShift, source: source)
        }
        postKey(shift, keyDown: false, flags: [], source: source)
        _ = await sleep(nanoseconds: 30_000_000)
    }

    /// Clicks the centre of the captured input frame, then restores the pointer.
    public func focusInputByClick(at frame: CGRect) async {
        guard frame.width > 1, frame.height > 1 else {
            return
        }
        guard !Task.isCancelled else { return }

        let target = CGPoint(x: frame.midX, y: frame.midY)
        let previousLocation = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: target,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: target,
                mouseButton: .left
            )
        else {
            return
        }

        SyntheticEventMarker.tag(mouseDown)
        SyntheticEventMarker.tag(mouseUp)
        mouseDown.post(tap: .cghidEventTap)
        guard await sleep(nanoseconds: 15_000_000) else {
            mouseUp.post(tap: .cghidEventTap)
            return
        }
        mouseUp.post(tap: .cghidEventTap)
        _ = await sleep(nanoseconds: 15_000_000)

        if let previousLocation {
            CGWarpMouseCursorPosition(previousLocation)
        }
    }

    private func postKey(
        _ keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        SyntheticEventMarker.tag(event)
        event?.post(tap: .cghidEventTap)
    }
}
