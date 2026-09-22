import XCTest
@testable import ResAICore

final class DictationJoinerTests: XCTestCase {
    func testEnglishPrependsSpaceWhenPrecededByNonWhitespace() {
        XCTAssertEqual(
            DictationJoiner.prepare("world", precededBy: "hello", localeIdentifier: "en_US"),
            " world"
        )
    }

    func testEnglishDoesNotPrependWhenBeforeEndsWithSpace() {
        XCTAssertEqual(
            DictationJoiner.prepare("world", precededBy: "hello ", localeIdentifier: "en_US"),
            "world"
        )
    }

    func testEnglishDoesNotPrependWhenBeforeEndsWithNewline() {
        XCTAssertEqual(
            DictationJoiner.prepare("world", precededBy: "hello\n", localeIdentifier: "en_US"),
            "world"
        )
    }

    func testJapaneseUnchanged() {
        XCTAssertEqual(
            DictationJoiner.prepare("世界", precededBy: "こんにちは", localeIdentifier: "ja_JP"),
            "世界"
        )
    }

    func testChineseAndKoreanUnchanged() {
        XCTAssertEqual(
            DictationJoiner.prepare("世界", precededBy: "你好", localeIdentifier: "zh_CN"),
            "世界"
        )
        XCTAssertEqual(
            DictationJoiner.prepare("세계", precededBy: "안녕", localeIdentifier: "ko_KR"),
            "세계"
        )
    }

    func testEmptyOrNilBeforeLeavesTextUnchanged() {
        XCTAssertEqual(
            DictationJoiner.prepare("hello", precededBy: nil, localeIdentifier: "en_US"),
            "hello"
        )
        XCTAssertEqual(
            DictationJoiner.prepare("hello", precededBy: "", localeIdentifier: "en_US"),
            "hello"
        )
    }

    func testNeverAppendsTrailingSpace() {
        let joined = DictationJoiner.prepare("world", precededBy: "hello", localeIdentifier: "en_GB")
        XCTAssertEqual(joined, " world")
        XCTAssertFalse(joined.hasSuffix("  "))
        XCTAssertEqual(joined.last, "d")
    }
}
