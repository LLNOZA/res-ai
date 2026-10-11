import XCTest
@testable import ResAICore

@MainActor
final class ClaudeAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClaudeAPIStub.reset()
    }

    override func tearDown() {
        ClaudeAPIStub.reset()
        super.tearDown()
    }

    // MARK: - Request

    func testMessagesRequestUsesFixedModelHeadersAndOmitsSamplingParameters() throws {
        let request = try ClaudeAPIClient.makeMessagesRequest(
            apiKey: "test-key",
            systemInstruction: "system text",
            userPrompt: "user text",
            maxTokens: 1234,
            timeout: 5
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.01)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")

        let json = try Self.jsonBody(request.httpBody)
        XCTAssertEqual(Set(json.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 1234)
        XCTAssertEqual(json["system"] as? String, "system text")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "user text")
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])
    }

    func testRewriteSendsPromptPairWithDefaultMaxTokens() async throws {
        ClaudeAPIStub.setResponse(body: Self.messagesBody(text: "「整った返信です。」"))
        let builder = RewritePromptBuilder()

        let result = try await makeClient().rewrite(Self.sampleRewrite)

        XCTAssertEqual(result.source, .claudeAPI)
        XCTAssertEqual(result.text, GeneratedReplySanitizer.sanitize("「整った返信です。」"))
        let recorded = try XCTUnwrap(ClaudeAPIStub.requests.first)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.apiKey, "test-key")
        let json = try Self.jsonBody(recorded.httpBody)
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(json["system"] as? String, builder.systemInstruction())
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, builder.userPrompt(for: Self.sampleRewrite))
        XCTAssertNil(json["temperature"])
    }

    func testMissingKeyFailsWithoutNetwork() async {
        let client = ClaudeAPIClient(apiKeyProvider: { "  " }, urlSession: Self.makeSession())
        do {
            _ = try await client.generateText(systemInstruction: "s", userPrompt: "u", timeout: 1)
            XCTFail("Expected missing key")
        } catch ClaudeAPIError.missingAPIKey {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(ClaudeAPIStub.requests.isEmpty)
    }

    // MARK: - Response

    func testParsesTextBlocks() throws {
        let text = try ClaudeAPIClient.parseMessagesResponse(Self.messagesBody(text: "こんにちは。"))
        XCTAssertEqual(text, "こんにちは。")
    }

    func testAcceptsStopSequence() throws {
        let text = try ClaudeAPIClient.parseMessagesResponse(
            Self.messagesBody(text: "ok", stopReason: "stop_sequence")
        )
        XCTAssertEqual(text, "ok")
    }

    func testRejectsMaxTokensStop() {
        XCTAssertThrowsError(
            try ClaudeAPIClient.parseMessagesResponse(Self.messagesBody(text: "partial", stopReason: "max_tokens"))
        ) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .incompleteResponse(stopReason: "max_tokens"))
        }
    }

    func testRejectsEmptyText() {
        XCTAssertThrowsError(try ClaudeAPIClient.parseMessagesResponse(Self.messagesBody(text: "  \n"))) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .emptyText)
        }
        let noBlocks = Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertThrowsError(try ClaudeAPIClient.parseMessagesResponse(noBlocks)) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .emptyText)
        }
    }

    func testDropsThinkingBlocks() throws {
        let body = Data("""
        {
          "content": [
            {"type": "thinking", "thinking": "hidden reasoning", "signature": "sig"},
            {"type": "redacted_thinking", "data": "opaque"},
            {"type": "text", "text": "答えです。"}
          ],
          "stop_reason": "end_turn"
        }
        """.utf8)
        XCTAssertEqual(try ClaudeAPIClient.parseMessagesResponse(body), "答えです。")

        let thinkingOnly = Data(#"{"content":[{"type":"thinking","thinking":"only thoughts"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertThrowsError(try ClaudeAPIClient.parseMessagesResponse(thinkingOnly)) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .emptyText)
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try ClaudeAPIClient.parseMessagesResponse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .invalidResponse)
        }
    }

    func testHTTPErrorKeepsOnlyStatusAndNeverReflectsBody() async {
        let secretBody = #"{"type":"error","error":{"type":"invalid_request_error","message":"leaked-body-detail test-key"}}"#
        ClaudeAPIStub.setResponse(body: Data(secretBody.utf8), statusCode: 400)

        do {
            _ = try await makeClient().generateText(systemInstruction: "s", userPrompt: "secret prompt", timeout: 2)
            XCTFail("Expected HTTP failure")
        } catch let error as ClaudeAPIError {
            XCTAssertEqual(error, .apiError(statusCode: 400))
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("400"))
            XCTAssertFalse(description.contains("leaked-body-detail"))
            XCTAssertFalse(description.contains("test-key"))
            XCTAssertFalse(description.contains("secret prompt"))
            XCTAssertFalse(String(describing: error).contains("leaked-body-detail"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHonorsTimeout() async {
        ClaudeAPIStub.setResponse(body: Self.messagesBody(text: "遅延"), hang: true)
        do {
            _ = try await makeClient().generateText(systemInstruction: "s", userPrompt: "u", timeout: 0.15)
            XCTFail("Expected timeout")
        } catch ClaudeAPIError.timeout {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationPropagates() async {
        ClaudeAPIStub.setResponse(body: Self.messagesBody(text: "遅延"), hang: true)
        let client = makeClient()
        let task = Task { @MainActor in
            try await client.generateText(systemInstruction: "s", userPrompt: "u", timeout: 5)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Key check

    func testVerifyAPIKeyUsesModelsEndpoint() async throws {
        ClaudeAPIStub.setResponse(body: Data(#"{"data":[]}"#.utf8))

        try await makeClient().verifyAPIKey(timeout: 2)

        let recorded = try XCTUnwrap(ClaudeAPIStub.requests.first)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(recorded.httpMethod, "GET")
        XCTAssertEqual(recorded.apiKey, "test-key")
        XCTAssertEqual(recorded.anthropicVersion, "2023-06-01")
    }

    func testVerifyAPIKeyFailsOnUnauthorized() async {
        ClaudeAPIStub.setResponse(body: Data(#"{"error":"nope"}"#.utf8), statusCode: 401)
        do {
            try await makeClient().verifyAPIKey(timeout: 2)
            XCTFail("Expected failure")
        } catch let error as ClaudeAPIError {
            XCTAssertEqual(error, .apiError(statusCode: 401))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Key storage

    func testAPIKeyIsStoredOnlyInSecretStoreNeverInUserDefaults() throws {
        let suiteName = "ClaudeAPIKeyStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secretStore = ClaudeMemorySecretStore()

        try ClaudeAPIKeyStore.save("  test-key-claude  ", secretStore: secretStore)
        try VertexAIConfig(projectID: "").save(to: defaults, secretStore: ClaudeMemorySecretStore())
        VoiceInputSettings().save(defaults: defaults)

        XCTAssertEqual(secretStore.values[ClaudeAPIKeyStore.account], "test-key-claude")
        XCTAssertEqual(ClaudeAPIKeyStore.load(secretStore: secretStore), "test-key-claude")
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(persisted.isEmpty)
        for (key, value) in persisted {
            XCTAssertFalse(key.contains("anthropic"), "Unexpected defaults key \(key)")
            XCTAssertFalse(String(describing: value).contains("test-key-claude"), "Key leaked into defaults[\(key)]")
        }
        XCTAssertNil(UserDefaults.standard.string(forKey: ClaudeAPIKeyStore.account))
    }

    func testDeleteRemovesStoredKey() throws {
        let secretStore = ClaudeMemorySecretStore()
        try ClaudeAPIKeyStore.save("test-key", secretStore: secretStore)
        XCTAssertTrue(ClaudeAPIKeyStore.hasKey(secretStore: secretStore))

        try ClaudeAPIKeyStore.delete(secretStore: secretStore)

        XCTAssertNil(ClaudeAPIKeyStore.load(secretStore: secretStore))
        XCTAssertFalse(ClaudeAPIKeyStore.hasKey(secretStore: secretStore))
    }

    func testBackendRoutePriority() {
        let proxy = VertexAIConfig(projectID: "", proxyURLString: "https://proxy.invalid/v1/rewrite")
        let none = VertexAIConfig(projectID: "")
        XCTAssertEqual(AIBackendRoute.select(hasClaudeKey: true, config: proxy), .claudeAPI)
        XCTAssertEqual(AIBackendRoute.select(hasClaudeKey: true, config: none), .claudeAPI)
        XCTAssertEqual(AIBackendRoute.select(hasClaudeKey: false, config: proxy), .proxy)
        XCTAssertEqual(AIBackendRoute.select(hasClaudeKey: false, config: none), .preview)
    }

    // MARK: - Helpers

    private func makeClient() -> ClaudeAPIClient {
        ClaudeAPIClient(apiKeyProvider: { "test-key" }, urlSession: Self.makeSession())
    }

    static let sampleRewrite = RewriteRequest(
        appInfo: AppInfo(name: "Test", bundleIdentifier: nil, processIdentifier: nil),
        draft: "下書き",
        context: "",
        mode: .balanced
    )

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeAPIStub.self]
        return URLSession(configuration: configuration)
    }

    static func messagesBody(text: String, stopReason: String = "end_turn") -> Data {
        let object: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-5-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func jsonBody(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class ClaudeMemorySecretStore: SecretStringStoring {
    var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func setString(_ value: String, for account: String) throws {
        values[account] = value.isEmpty ? nil : value
    }
}

/// Records requests and answers every host (Claude API and the proxy) with one canned response.
final class ClaudeAPIStub: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var url: URL?
        var httpMethod: String?
        var apiKey: String?
        var anthropicVersion: String?
        var proxyKey: String?
        var httpBody: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var hang = false
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []

    static var requests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    static func setResponse(body value: Data, statusCode code: Int = 200, hang shouldHang: Bool = false) {
        lock.withLock {
            body = value
            statusCode = code
            hang = shouldHang
        }
    }

    static func reset() {
        lock.withLock {
            body = Data()
            statusCode = 200
            hang = false
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = request
        let recorded = RecordedRequest(
            url: current.url,
            httpMethod: current.httpMethod,
            apiKey: current.value(forHTTPHeaderField: "x-api-key"),
            anthropicVersion: current.value(forHTTPHeaderField: "anthropic-version"),
            proxyKey: current.value(forHTTPHeaderField: "X-ResAI-Proxy-Key"),
            httpBody: Self.readBody(current)
        )
        let (data, code, shouldHang) = Self.lock.withLock { () -> (Data, Int, Bool) in
            Self._requests.append(recorded)
            return (Self.body, Self.statusCode, Self.hang)
        }
        if shouldHang {
            return
        }
        let response = HTTPURLResponse(url: current.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
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
