import XCTest
@testable import ResAICore

final class KeyboardSwapPlanTests: XCTestCase {
    func testShiftLeftCountUsesCharacterCount() {
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "hello"), 5)
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "こんにちは"), 5)
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "hi🌍"), 3)
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: ""), 0)
    }

    func testNewlinesCountAsOneCharacter() {
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "a\nb"), 3)
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "\n\n"), 2)
    }

    func testRejectsInsertedTextOver400Characters() {
        let allowed = String(repeating: "あ", count: KeyboardSwapPlan.maxInsertedCharacterCount)
        let rejected = allowed + "い"

        XCTAssertEqual(
            KeyboardSwapPlan.shiftLeftCount(for: allowed),
            KeyboardSwapPlan.maxInsertedCharacterCount
        )
        XCTAssertNil(KeyboardSwapPlan.shiftLeftCount(for: rejected))
        XCTAssertNil(KeyboardSwapPlan.shiftLeftCount(for: String(repeating: "a", count: 401)))
    }

    func testEmojiGraphemeClustersCountAsOne() {
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "👨‍👩‍👧‍👦"), 1)
        XCTAssertEqual(KeyboardSwapPlan.shiftLeftCount(for: "a👨‍👩‍👧‍👦b"), 3)
    }

    func testSkipReasonLabelForTooLong() {
        XCTAssertEqual(KeyboardSwapSkipReason.insertedTextTooLong.logLabel, "inserted text over 400 chars")
        XCTAssertEqual(KeyboardSwapSkipReason.userTypedOrClicked.logLabel, "user typed or clicked")
    }
}
