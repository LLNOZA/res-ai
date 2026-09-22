import XCTest
@testable import ResAICore

final class InputSynthesizerCancellationTests: XCTestCase {
    func testCancelledQueuedJobNeverExecutesItsBody() async throws {
        let events = RecordedInputEvents()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let first = Task.detached {
            try await InputSynthesizer.shared.run {
                signal.yield(())
                signal.finish()
                try await Task.sleep(for: .milliseconds(80))
                events.append("first")
            }
        }
        for await _ in started { break }
        let second = Task.detached {
            try await InputSynthesizer.shared.run { events.append("cancelled") }
        }
        second.cancel()
        do { try await second.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await first.value
        try await InputSynthesizer.shared.run { events.append("next") }
        XCTAssertEqual(events.snapshot, ["first", "next"])
    }
}

private final class RecordedInputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}
