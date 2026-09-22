import XCTest
@testable import ResAICore

final class BoundedDurationPolicyTests: XCTestCase {
    func testDropOldestKeepsNewestWithinBudget() {
        let kept = BoundedDurationPolicy.dropOldest(
            durations: [4, 4, 4, 3],
            maxDuration: 10
        )
        XCTAssertEqual(kept, [4, 3])
        XCTAssertEqual(kept.reduce(0, +), 7)
    }

    func testDropOldestAlwaysRetainsNewestItem() {
        let kept = BoundedDurationPolicy.dropOldest(durations: [12], maxDuration: 10)
        XCTAssertEqual(kept, [12])
    }

    func testDropOldestEmpty() {
        XCTAssertEqual(BoundedDurationPolicy.dropOldest(durations: [], maxDuration: 10), [])
    }

    func testDropOldestDoesNotTrimWhenUnderBudget() {
        let durations: [TimeInterval] = [1, 2, 3]
        XCTAssertEqual(BoundedDurationPolicy.dropOldest(durations: durations, maxDuration: 10), durations)
    }
}
