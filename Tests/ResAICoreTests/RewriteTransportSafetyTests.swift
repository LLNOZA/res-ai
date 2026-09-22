import XCTest
@testable import ResAICore

final class RewriteTransportSafetyTests: XCTestCase {
    @MainActor
    func testProxyRejectsExplicitTruncationAndSupportsLegacyCompleteResponses() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = CloudRunProxyClient(configProvider: {
            VertexAIConfig(projectID: "test", proxyURLString: "https://test.invalid/rewrite", proxyAuthToken: "test-only")
        }, urlSession: session)
        RewriteTransportStub.setBody(#"{"text":"partial", "finishReason":"MAX_TOKENS"}"#)
        do { _ = try await client.rewrite(sample); XCTFail("Must reject truncated text") }
        catch CloudRunProxyError.incompleteResponse { }
        RewriteTransportStub.setBody(#"{"text":"complete"}"#)
        let result = try await client.rewrite(sample)
        XCTAssertEqual(result.text, "complete")
    }

    @MainActor
    func testVertexRejectsPartialAndMissingFinishReasonAndFiltersThoughts() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = VertexAIClient(configProvider: { VertexAIConfig(projectID: "test") },
                                    tokenProvider: EnvironmentAccessTokenProvider(environment: ["VERTEX_AI_ACCESS_TOKEN": "test"]),
                                    urlSession: session)
        for reason in [#""finishReason":"MAX_TOKENS","#, ""] {
            RewriteTransportStub.setBody("{\"candidates\":[{\(reason)\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}")
            do { _ = try await client.rewrite(sample); XCTFail("Must reject incomplete text") }
            catch VertexAIError.incompleteResponse { }
        }
        RewriteTransportStub.setBody(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"reasoning"},{"text":"reply"}]}}]}"#)
        let result = try await client.rewrite(sample)
        XCTAssertEqual(result.text, "reply")
    }

    private var sample: RewriteRequest {
        RewriteRequest(appInfo: AppInfo(name: "Test", bundleIdentifier: nil, processIdentifier: nil), draft: "draft", context: "", mode: .balanced)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RewriteTransportStub.self]
        return URLSession(configuration: config)
    }
}

private final class RewriteTransportStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var data = Data()
    static func setBody(_ value: String) { lock.withLock { data = Data(value.utf8) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.lock.withLock { Self.data })
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
