import XCTest
@testable import ResAICore

final class ContextWindowTests: XCTestCase {
    func testReturnsAllWhenWithinLimit() {
        XCTAssertEqual(ContextWindow.headAndTail(["a", "b", "c"], limit: 3), ["a", "b", "c"])
        XCTAssertEqual(ContextWindow.headAndTail(["a", "b"], limit: 8), ["a", "b"])
    }

    func testKeepsOpeningAndLatestWhenOverLimit() {
        let lines = (1...10).map(String.init)
        // limit 8 → head 2 + tail 6
        XCTAssertEqual(ContextWindow.headAndTail(lines, limit: 8), ["1", "2", "5", "6", "7", "8", "9", "10"])
    }

    func testLimitTwoKeepsFirstAndLast() {
        XCTAssertEqual(ContextWindow.headAndTail(["古い", "中", "新しい"], limit: 2), ["古い", "新しい"])
    }

    func testEmptyLimit() {
        XCTAssertEqual(ContextWindow.headAndTail(["a"], limit: 0), [String]())
    }
}
