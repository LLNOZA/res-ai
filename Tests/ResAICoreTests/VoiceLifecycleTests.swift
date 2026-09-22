import XCTest
@testable import ResAICore

@MainActor
final class VoiceLifecycleTests: XCTestCase {
    func testVoiceSessionLifecycleBeginAndInvalidateUseMonotonicIDs() {
        var lifecycle = VoiceSessionLifecycle()

        let first = lifecycle.begin()
        let second = lifecycle.begin()

        XCTAssertLessThan(first.rawValue, second.rawValue)
        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.isCurrent(second))

        lifecycle.invalidate()
        let third = lifecycle.begin()

        XCTAssertGreaterThan(third.rawValue, second.rawValue)
        XCTAssertFalse(lifecycle.isCurrent(second))
        XCTAssertTrue(lifecycle.isCurrent(third))
    }

    func testVoiceLifecycleTimeoutReturnsFastResult() async {
        let start = ContinuousClock.now
        let result = await VoiceLifecycleTimeout.run(timeout: .seconds(1)) {
            return "ready"
        }
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(result, "ready")
        XCTAssertLessThan(elapsed, .seconds(0.5))
    }

    func testVoiceLifecycleTimeoutHardTimeoutDoesNotAwaitNoncooperativeContinuation() async {
        let latch = ContinuationLatch()
        let start = ContinuousClock.now
        let result = await VoiceLifecycleTimeout.run(timeout: .milliseconds(30)) {
            _ = await withCheckedContinuation { continuation in
                latch.store(continuation)
            }
            return "late"
        }
        let elapsed = start.duration(to: .now)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .seconds(0.5))

        // Release the deliberately non-cooperative operation so the test does
        // not leave a suspended checked continuation behind.
        latch.resume("late")
    }

    func testVoiceLifecycleTimeoutCallerCancellationReturnsPromptly() async {
        let latch = ContinuationLatch()
        let caller = Task { @MainActor in
            await VoiceLifecycleTimeout.run(timeout: .seconds(10)) {
                _ = await withCheckedContinuation { continuation in
                    latch.store(continuation)
                }
                return "cancelled"
            }
        }

        await latch.waitUntilStored()
        let start = ContinuousClock.now
        caller.cancel()
        let result = await caller.value
        let elapsed = start.duration(to: .now)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .seconds(0.5))
        latch.resume("cancelled")
    }

    func testVoiceLifecycleTimeoutLateCompletionDoesNotAffectNextRun() async {
        let firstLatch = ContinuationLatch()
        let first = await VoiceLifecycleTimeout.run(timeout: .milliseconds(25)) {
            _ = await withCheckedContinuation { continuation in
                firstLatch.store(continuation)
            }
            return "old"
        }

        XCTAssertNil(first)
        firstLatch.resume("old")

        let second = await VoiceLifecycleTimeout.run(timeout: .seconds(1)) {
            return "new"
        }

        XCTAssertEqual(second, "new")
    }
}

private final class ContinuationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var pendingValue: String?

    var hasStoredContinuation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func store(_ continuation: CheckedContinuation<String, Never>) {
        lock.lock()
        if let pendingValue {
            self.pendingValue = nil
            lock.unlock()
            continuation.resume(returning: pendingValue)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(_ value: String) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            pendingValue = value
            lock.unlock()
        }
    }

    func waitUntilStored() async {
        while !hasStoredContinuation {
            await Task.yield()
        }
    }
}
