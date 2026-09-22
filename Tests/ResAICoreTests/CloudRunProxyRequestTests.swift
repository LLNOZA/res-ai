import XCTest
@testable import ResAICore

final class CloudRunProxyRequestTests: XCTestCase {
    func testProxyRequestDoesNotCarryModelConfiguration() throws {
        let request = CloudRunProxyRewriteRequest(
            systemInstruction: "system",
            userPrompt: "user"
        )

        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("systemInstruction"))
        XCTAssertTrue(json.contains("userPrompt"))
        XCTAssertFalse(json.contains("projectID"))
        XCTAssertFalse(json.contains("location"))
        XCTAssertFalse(json.contains("model"))
    }
}
