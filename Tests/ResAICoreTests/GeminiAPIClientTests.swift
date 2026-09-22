import XCTest
@testable import ResAICore

final class GeminiAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GeminiURLProtocolStub.reset()
    }

    override func tearDown() {
        GeminiURLProtocolStub.reset()
        super.tearDown()
    }

    func testDefaultSessionUsesEphemeralPerformanceSettings() {
        let client = GeminiAPIClient(apiKeyProvider: { "k" }, model: { "m" })
        let config = client.sessionConfiguration
        XCTAssertEqual(config.timeoutIntervalForRequest, 6, accuracy: 0.01)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 4)
        XCTAssertNil(config.urlCache)
    }

    func testGenerateTextSendsAPIKeyHeaderAndModelInURL() async throws {
        GeminiURLProtocolStub.handler = { request in
            GeminiURLProtocolStub.StubResponse(statusCode: 200, data: Self.successBody("整いました。"))
        }

        let client = makeClient()
        let text = try await client.generateText(Self.sampleRequest, timeout: 2)

        XCTAssertEqual(text, "整いました。")
        let request = try XCTUnwrap(GeminiURLProtocolStub.requests.first)
        XCTAssertEqual(request.apiKey, "test-key")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.absoluteString.contains("gemini-3.8-flash") == true)
        XCTAssertTrue(request.url?.absoluteString.contains(":generateContent") == true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertNotNil(config["thinkingConfig"])
    }

    func testGenerateTextParsesJoinedCandidateParts() async throws {
        let body = """
        {
          "candidates": [
            {
              "finishReason": "STOP",
              "content": {
                "parts": [
                  { "text": "こんに" },
                  { "text": "ちは。" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!
        GeminiURLProtocolStub.handler = { _ in
            GeminiURLProtocolStub.StubResponse(statusCode: 200, data: body)
        }

        let text = try await makeClient().generateText(Self.sampleRequest, timeout: 2)
        XCTAssertEqual(text, "こんにちは。")
    }

    func testGenerateTextRetriesOnceWhenThinkingConfigIsRejected() async throws {
        let counter = RequestCounter()
        GeminiURLProtocolStub.handler = { request in
            let count = counter.increment()
            if count == 1 {
                return GeminiURLProtocolStub.StubResponse(
                    statusCode: 400,
                    data: Data("Unknown name thinkingConfig in generationConfig".utf8)
                )
            }
            return GeminiURLProtocolStub.StubResponse(statusCode: 200, data: Self.successBody("補正済み"))
        }

        let text = try await makeClient().generateText(Self.sampleRequest, timeout: 2)
        XCTAssertEqual(text, "補正済み")
        XCTAssertEqual(GeminiURLProtocolStub.requests.count, 2)

        let firstBody = try XCTUnwrap(GeminiURLProtocolStub.requests[0].httpBody)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        let firstConfig = try XCTUnwrap(firstJSON["generationConfig"] as? [String: Any])
        XCTAssertNotNil(firstConfig["thinkingConfig"])

        let secondBody = try XCTUnwrap(GeminiURLProtocolStub.requests[1].httpBody)
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let secondConfig = try XCTUnwrap(secondJSON["generationConfig"] as? [String: Any])
        XCTAssertNil(secondConfig["thinkingConfig"])
    }

    func testGenerateTextMapsTimeout() async {
        GeminiURLProtocolStub.handler = { _ in
            GeminiURLProtocolStub.StubResponse(statusCode: 200, data: Self.successBody("遅延"), hang: true)
        }

        do {
            _ = try await makeClient().generateText(Self.sampleRequest, timeout: 0.15)
            XCTFail("Expected timeout")
        } catch let error as GeminiAPIError {
            guard case .timeout = error else {
                XCTFail("Expected GeminiAPIError.timeout, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected GeminiAPIError.timeout, got \(error)")
        }
    }

    func testPartialOutputIsRejectedEvenWhenTextIsPresent() async {
        GeminiURLProtocolStub.handler = { _ in
            let data = Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial reply"}]}}]}"#.utf8)
            return GeminiURLProtocolStub.StubResponse(statusCode: 200, data: data)
        }
        do {
            _ = try await makeClient().generateText(Self.sampleRequest, timeout: 1)
            XCTFail("Must not accept a truncated reply")
        } catch GeminiAPIError.incompleteText(let reason) {
            XCTAssertEqual(reason, "MAX_TOKENS")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testThoughtPartsAreNotReturned() async throws {
        GeminiURLProtocolStub.handler = { _ in
            let data = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"reasoning","thought":true},{"text":"reply"}]}}]}"#.utf8)
            return GeminiURLProtocolStub.StubResponse(statusCode: 200, data: data)
        }
        let result = try await makeClient().generateText(Self.sampleRequest, timeout: 1)
        XCTAssertEqual(result, "reply")
    }

    func testModelListUsesHeaderNotURLCredential() async throws {
        GeminiURLProtocolStub.handler = { _ in
            GeminiURLProtocolStub.StubResponse(statusCode: 200, data: Data(#"{"models":[{"name":"models/test"}]}"#.utf8))
        }
        let result = try await makeClient().listModels(timeout: 1)
        XCTAssertEqual(result, ["test"])
        let request = try XCTUnwrap(GeminiURLProtocolStub.requests.first)
        XCTAssertEqual(request.apiKey, "test-key")
        XCTAssertNil(request.url?.query)
    }

    func testCancellationReturnsWithoutWaitingForTimeout() async throws {
        GeminiURLProtocolStub.handler = { _ in
            GeminiURLProtocolStub.StubResponse(statusCode: 200, data: Data(), hang: true)
        }
        let client = makeClient()
        let request = Self.sampleRequest
        let task = Task.detached { try await client.generateText(request, timeout: 20) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeClient() -> GeminiAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        return GeminiAPIClient(
            apiKeyProvider: { "test-key" },
            model: { "gemini-3.8-flash" },
            urlSession: session
        )
    }

    private static var sampleRequest: GeminiTextRequest {
        GeminiTextRequest(
            systemInstruction: "sys",
            userPrompt: "user",
            maxOutputTokens: 64,
            temperature: 0.1
        )
    }

    private static func successBody(_ text: String) -> Data {
        """
        {
          "candidates": [
            {
              "finishReason": "STOP",
              "content": {
                "parts": [
                  { "text": "\(text)" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class GeminiURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        var statusCode: Int
        var data: Data
        var hang: Bool

        init(statusCode: Int, data: Data, hang: Bool = false) {
            self.statusCode = statusCode
            self.data = data
            self.hang = hang
        }
    }

    struct RecordedRequest: Sendable {
        var url: URL?
        var httpMethod: String?
        var apiKey: String?
        var httpBody: Data?

        init(_ request: URLRequest) {
            url = request.url
            httpMethod = request.httpMethod
            apiKey = request.value(forHTTPHeaderField: "x-goog-api-key")
            httpBody = Self.body(from: request)
        }

        private static func body(from request: URLRequest) -> Data? {
            if let body = request.httpBody {
                return body
            }
            guard let stream = request.httpBodyStream else {
                return nil
            }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read <= 0 {
                    break
                }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) throws -> StubResponse)?
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []

    static var handler: (@Sendable (URLRequest) throws -> StubResponse)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    static func reset() {
        lock.lock()
        _handler = nil
        _requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = request
        let recorded = RecordedRequest(current)
        Self.lock.lock()
        Self._requests.append(recorded)
        let handler = Self._handler
        Self.lock.unlock()

        do {
            guard let handler else {
                throw URLError(.badServerResponse)
            }
            let stub = try handler(current)
            if stub.hang {
                return
            }
            let response = HTTPURLResponse(
                url: current.url ?? URL(string: "https://generativelanguage.googleapis.com")!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
