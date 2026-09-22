import Foundation

/// A monotonically increasing identity for one voice input session.
///
/// Session identities are deliberately value types.  A callback may outlive the
/// object which created it, so comparing the captured identity with the current
/// one is safer than relying on task cancellation alone.
public struct VoiceSessionID: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct VoiceSessionLifecycle: Equatable, Sendable {
    private var nextRawValue: UInt64 = 0
    public private(set) var active: VoiceSessionID?

    public init() {}

    @discardableResult
    public mutating func begin() -> VoiceSessionID {
        nextRawValue &+= 1
        let id = VoiceSessionID(rawValue: nextRawValue)
        active = id
        return id
    }

    public mutating func invalidate() {
        nextRawValue &+= 1
        active = nil
    }

    public func isCurrent(_ id: VoiceSessionID) -> Bool {
        active == id
    }
}

/// Races an async operation with a cancellation-aware timeout without a
/// structured task group.  A non-cooperative framework operation is cancelled
/// when possible, but its unstructured task is intentionally not awaited after
/// the timeout.  This keeps microphone/UI recovery bounded.
public enum VoiceLifecycleTimeout {
    private enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        case timedOut
    }

    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<Value>, Never>?
        private var pending: Outcome<Value>?
        private var resolved = false

        func install(_ continuation: CheckedContinuation<Outcome<Value>, Never>) {
            lock.lock()
            if let pending {
                self.pending = nil
                resolved = true
                lock.unlock()
                continuation.resume(returning: pending)
            } else if resolved {
                // `resolve` can win between task creation and continuation
                // installation.  This branch should only be reachable for a
                // timed-out outcome, which is retained in `pending` above.
                lock.unlock()
                continuation.resume(returning: .timedOut)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resolve(_ outcome: Outcome<Value>) {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            // Keep the result until the waiting continuation has been installed.
            pending = outcome
            lock.unlock()
        }
    }

    /// Returns `nil` when the timeout wins.  The operation task is unstructured
    /// on purpose: awaiting it after a timeout would reintroduce an unbounded
    /// wait for framework code that ignores cancellation.
    public static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> Value? {
        let once = Once<Value>()
        let operationTask = Task { @MainActor in
            once.resolve(.value(await operation()))
        }
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            once.resolve(.timedOut)
        }

        let outcome = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                once.install(continuation)
            }
        }, onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            once.resolve(.timedOut)
        })

        timeoutTask.cancel()
        if case .value(let value) = outcome {
            return value
        }
        operationTask.cancel()
        return nil
    }
}
