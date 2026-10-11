import XCTest
@testable import ResAICore

final class DictationCleanupRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProxyCleanupStub.reset()
    }

    override func tearDown() {
        ProxyCleanupStub.reset()
        super.tearDown()
    }

    func testRouteSelection() {
        XCTAssertEqual(DictationCleanupRoute.select(proxyConfigured: true, hasGeminiKey: true), .proxy)
        XCTAssertEqual(DictationCleanupRoute.select(proxyConfigured: true, hasGeminiKey: false), .proxy)
        XCTAssertEqual(DictationCleanupRoute.select(proxyConfigured: false, hasGeminiKey: true), .gemini)
        XCTAssertEqual(DictationCleanupRoute.select(proxyConfigured: false, hasGeminiKey: false), .none)
        XCTAssertEqual(DictationCleanupRoute.select(config: Self.proxyConfig, hasGeminiKey: true), .proxy)
        XCTAssertEqual(DictationCleanupRoute.select(config: VertexAIConfig(projectID: ""), hasGeminiKey: true), .gemini)
    }

    @MainActor
    func testProxyCleanerSendsDictationPromptsOverProxyContract() async throws {
        ProxyCleanupStub.setResponse(body: #"{"text":"これは接続テストです。","model":"claude-haiku-5-5"}"#)
        let request = Self.sampleRequest(style: .rewrite)

        let cleaned = try await makeProxyCleaner().cleanup(request, timeout: 2)

        XCTAssertEqual(cleaned, "これは接続テストです。")
        let recorded = try XCTUnwrap(ProxyCleanupStub.requests.first)
        XCTAssertEqual(ProxyCleanupStub.requests.count, 1)
        XCTAssertEqual(recorded.url?.absoluteString, "https://proxy.invalid/v1/rewrite")
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.proxyKey, "test-only")
        let body = try XCTUnwrap(recorded.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let builder = DictationCleanupPromptBuilder()
        XCTAssertEqual(Set(json.keys), ["systemInstruction", "userPrompt"])
        XCTAssertEqual(json["systemInstruction"] as? String, builder.systemInstruction(style: .rewrite))
        XCTAssertEqual(json["userPrompt"] as? String, builder.userPrompt(for: request))
    }

    @MainActor
    func testProxyCleanerSanitizesOutput() async throws {
        ProxyCleanupStub.setResponse(body: #"{"text":"「これは接続テストです。」"}"#)
        let cleaned = try await makeProxyCleaner().cleanup(Self.sampleRequest(), timeout: 2)
        XCTAssertEqual(cleaned, GeneratedReplySanitizer.sanitize("「これは接続テストです。」"))
    }

    @MainActor
    func testProxyCleanerRejectsOverlongOutput() async {
        let long = String(repeating: "追加された文章です。", count: 20)
        ProxyCleanupStub.setResponse(body: "{\"text\":\"\(long)\"}")
        do {
            _ = try await makeProxyCleaner().cleanup(Self.sampleRequest(), timeout: 2)
            XCTFail("Must reject output that grew far beyond the transcript")
        } catch DictationCleanupError.rejectedOutput {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testProxyCleanerSurfacesHTTPFailure() async {
        ProxyCleanupStub.setResponse(body: #"{"error":"upstream"}"#, statusCode: 502)
        do {
            _ = try await makeProxyCleaner().cleanup(Self.sampleRequest(), timeout: 2)
            XCTFail("Expected failure")
        } catch CloudRunProxyError.apiError(let statusCode, _) {
            XCTAssertEqual(statusCode, 502)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testProxyCleanerHonorsTimeout() async {
        ProxyCleanupStub.setResponse(body: #"{"text":"遅延"}"#, hang: true)
        do {
            _ = try await makeProxyCleaner().cleanup(Self.sampleRequest(), timeout: 0.15)
            XCTFail("Expected timeout")
        } catch CloudRunProxyError.timeout {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRouterUsesProxyAndNeverCallsGeminiWhenProxyConfigured() async throws {
        let proxy = SpyCleaner(result: .success("proxy"))
        let gemini = SpyCleaner(result: .success("gemini"))
        let router = DictationCleanupRouter(config: Self.proxyConfig, proxyCleaner: proxy, geminiCleaner: gemini)

        let cleaned = try await router.cleanup(Self.sampleRequest(), timeout: 1)

        XCTAssertEqual(router.route, .proxy)
        XCTAssertEqual(cleaned, "proxy")
        XCTAssertEqual(proxy.callCount, 1)
        XCTAssertEqual(gemini.callCount, 0)
    }

    @MainActor
    func testRouterWithRealProxyCleanerDoesNotReachGemini() async throws {
        ProxyCleanupStub.setResponse(body: #"{"text":"これは接続テストです。"}"#)
        let gemini = SpyCleaner(result: .success("gemini"))
        let router = DictationCleanupRouter(
            config: Self.proxyConfig,
            proxyCleaner: makeProxyCleaner(),
            geminiCleaner: gemini
        )

        _ = try await router.cleanup(Self.sampleRequest(), timeout: 2)

        XCTAssertEqual(gemini.callCount, 0)
        XCTAssertTrue(ProxyCleanupStub.requests.allSatisfy { $0.url?.host == "proxy.invalid" })
    }

    func testRouterFallsBackToGeminiOnlyWithoutProxy() async throws {
        let proxy = SpyCleaner(result: .success("proxy"))
        let gemini = SpyCleaner(result: .success("gemini"))
        let router = DictationCleanupRouter(
            config: VertexAIConfig(projectID: ""),
            proxyCleaner: proxy,
            geminiCleaner: gemini
        )

        let cleaned = try await router.cleanup(Self.sampleRequest(), timeout: 1)

        XCTAssertEqual(router.route, .gemini)
        XCTAssertEqual(cleaned, "gemini")
        XCTAssertEqual(proxy.callCount, 0)
        XCTAssertEqual(gemini.callCount, 1)
    }

    func testRouterWithNeitherBackendLeavesRawText() async {
        let proxy = SpyCleaner(result: .success("proxy"))
        let router = DictationCleanupRouter(
            config: VertexAIConfig(projectID: ""),
            proxyCleaner: proxy,
            geminiCleaner: nil
        )

        XCTAssertEqual(router.route, .none)
        do {
            _ = try await router.cleanup(Self.sampleRequest(), timeout: 1)
            XCTFail("Expected notConfigured")
        } catch DictationCleanupError.notConfigured {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(proxy.callCount, 0)
    }

    func testRouterPropagatesProxyFailureWithoutFallingBackToGemini() async {
        let proxy = SpyCleaner(result: .failure(CloudRunProxyError.timeout))
        let gemini = SpyCleaner(result: .success("gemini"))
        let router = DictationCleanupRouter(config: Self.proxyConfig, proxyCleaner: proxy, geminiCleaner: gemini)

        do {
            _ = try await router.cleanup(Self.sampleRequest(), timeout: 1)
            XCTFail("Failure must reach the caller so the raw transcript stays in place")
        } catch CloudRunProxyError.timeout {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(gemini.callCount, 0)
    }

    private static var proxyConfig: VertexAIConfig {
        VertexAIConfig(
            projectID: "",
            proxyURLString: "https://proxy.invalid/v1/rewrite",
            proxyAuthToken: "test-only"
        )
    }

    private static func sampleRequest(style: DictationCleanupStyle = .light) -> DictationCleanupRequest {
        DictationCleanupRequest(
            rawText: "えーと、これは接続テストです",
            appInfo: AppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: nil),
            contextLines: ["精度の話"],
            dictionary: UserDictionary(),
            localeIdentifier: "ja_JP",
            style: style
        )
    }

    @MainActor
    private func makeProxyCleaner() -> ProxyDictationCleaner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyCleanupStub.self]
        let session = URLSession(configuration: configuration)
        let config = Self.proxyConfig
        return ProxyDictationCleaner(
            client: CloudRunProxyClient(configProvider: { config }, urlSession: session)
        )
    }
}

private final class SpyCleaner: DictationCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, Error>
    private var _callCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func cleanup(_ request: DictationCleanupRequest, timeout: TimeInterval) async throws -> String {
        lock.withLock { _callCount += 1 }
        return try result.get()
    }
}

private final class ProxyCleanupStub: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var url: URL?
        var httpMethod: String?
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

    static func setResponse(body value: String, statusCode code: Int = 200, hang shouldHang: Bool = false) {
        lock.withLock {
            body = Data(value.utf8)
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
