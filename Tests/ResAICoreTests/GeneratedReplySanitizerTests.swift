import XCTest
@testable import ResAICore

final class GeneratedReplySanitizerTests: XCTestCase {
    func testStripsCommonReplyPrefix() {
        XCTAssertEqual(
            GeneratedReplySanitizer.sanitize("返信文: ありがとうございます。明日でお願いします。"),
            "ありがとうございます。明日でお願いします。"
        )
    }

    func testStripsWrappingJapaneseQuotes() {
        XCTAssertEqual(
            GeneratedReplySanitizer.sanitize("「ありがとうございます。確認します。」"),
            "ありがとうございます。確認します。"
        )
    }

    func testStripsSingleListMarker() {
        XCTAssertEqual(
            GeneratedReplySanitizer.sanitize("- 明日14時で大丈夫です。"),
            "明日14時で大丈夫です。"
        )
    }

    func testStripsMarkdownFence() {
        let raw = """
        ```text
        ありがとうございます。では明日でお願いします。
        ```
        """

        XCTAssertEqual(
            GeneratedReplySanitizer.sanitize(raw),
            "ありがとうございます。では明日でお願いします。"
        )
    }
}
