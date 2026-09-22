import XCTest
@testable import ResAICore

final class CloudRunProxyClientTests: XCTestCase {
    func testProxyResponseDecodesText() throws {
        let json = """
        {
          "text": "ありがとうございます。明日で問題ありません。",
          "model": "gemini-3.5-flash",
          "location": "global"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CloudRunProxyRewriteResponse.self, from: json)

        XCTAssertEqual(decoded.text, "ありがとうございます。明日で問題ありません。")
        XCTAssertEqual(decoded.model, "gemini-3.5-flash")
        XCTAssertEqual(decoded.location, "global")
    }
}
