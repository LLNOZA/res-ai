import XCTest
@testable import ResAICore

final class VertexAIResponseTests: XCTestCase {
    func testDecodesPrimaryText() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "ありがとうございます。明日で問題ありません。" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VertexGenerateContentResponse.self, from: json)

        XCTAssertEqual(decoded.primaryText, "ありがとうございます。明日で問題ありません。")
    }

    func testSanitizesPrimaryTextForReplyUse() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "返信文: 「ありがとうございます。明日で問題ありません。」" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VertexGenerateContentResponse.self, from: json)
        let text = GeneratedReplySanitizer.sanitize(decoded.primaryText ?? "")

        XCTAssertEqual(text, "ありがとうございます。明日で問題ありません。")
    }
}
