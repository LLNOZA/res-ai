import XCTest
@testable import ResAICore

final class NetworkRequestSafetyTests: XCTestCase {
    func testEndpointValidation() throws {
        for raw in ["https://example.com/v1", "http://localhost:8080/v1", "http://127.0.0.1/v1", "http://[::1]/v1"] {
            XCTAssertTrue(NetworkRequestSafety.isAllowedURL(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in ["http://example.com/v1", "file:///tmp/data", "https://fixture-user:fixture-pass@example.test/v1", "ftp://example.com", "relative/path"] {
            XCTAssertFalse(NetworkRequestSafety.isAllowedURL(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testUpstreamBodiesAreNotIncludedInUserFacingErrors() {
        let sensitive = "confidential draft and secret-test-value"
        let errors: [any LocalizedError] = [
            GeminiAPIError.apiError(statusCode: 403, body: sensitive),
            VertexAIError.apiError(statusCode: 403, body: sensitive),
            CloudRunProxyError.apiError(statusCode: 403, body: sensitive)
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.contains(sensitive) ?? true)
            XCTAssertTrue(error.errorDescription?.contains("403") ?? false)
        }
    }

    func testHardTimeoutDoesNotAwaitNoncooperativeOperation() async {
        let start = ContinuousClock.now
        do {
            _ = try await NetworkRequestSafety.runWithTimeout(0.025, timeoutError: GeminiAPIError.timeout) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is GeminiAPIError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    func testInvalidDeadlinesDoNotTrap() async {
        for value in [Double.nan, .infinity, -1, 0] {
            do {
                _ = try await NetworkRequestSafety.runWithTimeout(value, timeoutError: GeminiAPIError.timeout) { "value" }
                XCTFail("Expected invalid timeout rejection")
            } catch { XCTAssertTrue(error is GeminiAPIError) }
        }
    }
}
