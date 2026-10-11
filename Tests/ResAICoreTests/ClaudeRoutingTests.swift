import XCTest
@testable import ResAICore

/// Route priority for all three AI features:
/// Claude API key → direct Claude API / proxy only → proxy / neither → local fallback.
@MainActor
final class ClaudeRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClaudeAPIStub.reset()
    }

    override func tearDown() {
        ClaudeAPIStub.reset()
        super.tearDown()
    }

    // MARK: - Reply rewrite

    func testRewriteUsesClaudeWhenKeyIsSetEvenWithProxy() async throws {
        let spies = RewriteSpies()
        let router = spies.makeRouter(config: Self.proxyConfig, claudeKey: "test-key")

        let result = try await router.rewrite(ClaudeAPIClientTests.sampleRewrite)

        XCTAssertEqual(result.text, "claude")
        XCTAssertEqual(spies.calls, ["claude"])
    }

    func testRewriteUsesProxyWhenOnlyProxyIsConfigured() async throws {
        let spies = RewriteSpies()
        let router = spies.makeRouter(config: Self.proxyConfig, claudeKey: nil)

        let result = try await router.rewrite(ClaudeAPIClientTests.sampleRewrite)

        XCTAssertEqual(result.text, "proxy")
        XCTAssertEqual(spies.calls, ["proxy"])
    }

    func testRewriteFallsBackToPreviewWithNeither() async throws {
        let spies = RewriteSpies()
        let router = spies.makeRouter(config: VertexAIConfig(projectID: ""), claudeKey: "   ")

        let result = try await router.rewrite(ClaudeAPIClientTests.sampleRewrite)

        XCTAssertEqual(result.text, "preview")
        XCTAssertEqual(spies.calls, ["preview"])
    }

    func testRewriteRouterWithRealClaudeClientReachesOnlyAnthropic() async throws {
        ClaudeAPIStub.setResponse(body: ClaudeAPIClientTests.messagesBody(text: "返信です。"))
        let config = Self.proxyConfig
        let router = RewriteRouter(
            configProvider: { config },
            claudeAPIKeyProvider: { "test-key" },
            claudeClient: ClaudeAPIClient(
                apiKeyProvider: { "test-key" },
                urlSession: ClaudeAPIClientTests.makeSession()
            )
        )

        let result = try await router.rewrite(ClaudeAPIClientTests.sampleRewrite)

        XCTAssertEqual(result.source, .claudeAPI)
        XCTAssertEqual(ClaudeAPIStub.requests.map { $0.url?.host }, ["api.anthropic.com"])
        XCTAssertNil(ClaudeAPIStub.requests.first?.proxyKey)
    }

    // MARK: - Form fill

    func testFormFillUsesClaudeWhenKeyIsSetEvenWithProxy() async throws {
        let items = #"{"items":[{"fieldIndex":0,"value":"AI Name","confidence":0.9,"reason":"profile"}]}"#
        ClaudeAPIStub.setResponse(body: ClaudeAPIClientTests.messagesBody(text: items))

        let suggestions = await makePlanner(config: Self.proxyConfig, claudeKey: "test-key").plan(Self.formRequest)

        XCTAssertEqual(suggestions.map(\.value), ["AI Name"])
        let recorded = try XCTUnwrap(ClaudeAPIStub.requests.first)
        XCTAssertEqual(ClaudeAPIStub.requests.count, 1)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.apiKey, "test-key")
        XCTAssertNil(recorded.proxyKey)
        let json = try ClaudeAPIClientTests.jsonBody(recorded.httpBody)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertNil(json["temperature"])
        XCTAssertTrue((json["system"] as? String)?.contains("フォーム入力候補") == true)
    }

    func testFormFillUsesProxyWhenOnlyProxyIsConfigured() async throws {
        let items = #"{"items":[{"fieldIndex":0,"value":"Proxy Name","confidence":0.9,"reason":"profile"}]}"#
        let proxyBody = try JSONSerialization.data(withJSONObject: ["text": items, "finishReason": "STOP"])
        ClaudeAPIStub.setResponse(body: proxyBody)

        let suggestions = await makePlanner(config: Self.proxyConfig, claudeKey: nil).plan(Self.formRequest)

        XCTAssertEqual(suggestions.map(\.value), ["Proxy Name"])
        let recorded = try XCTUnwrap(ClaudeAPIStub.requests.first)
        XCTAssertEqual(recorded.url?.host, "proxy.invalid")
        XCTAssertEqual(recorded.proxyKey, "test-only")
        XCTAssertNil(recorded.apiKey)
    }

    func testFormFillUsesLocalPlannerWithNeither() async {
        let suggestions = await makePlanner(config: VertexAIConfig(projectID: ""), claudeKey: nil).plan(Self.formRequest)

        XCTAssertEqual(suggestions.map(\.value), ["Example User"])
        XCTAssertTrue(ClaudeAPIStub.requests.isEmpty)
    }

    func testFormFillFallsBackToLocalWhenClaudeIsTruncated() async {
        let items = #"{"items":[{"fieldIndex":0,"value":"AI Name","confidence":0.9}]}"#
        ClaudeAPIStub.setResponse(body: ClaudeAPIClientTests.messagesBody(text: items, stopReason: "max_tokens"))

        let suggestions = await makePlanner(config: VertexAIConfig(projectID: ""), claudeKey: "test-key").plan(Self.formRequest)

        XCTAssertEqual(suggestions.map(\.value), ["Example User"])
        XCTAssertEqual(ClaudeAPIStub.requests.count, 1)
    }

    // MARK: - Dictation cleanup

    func testDictationRouteSelection() {
        XCTAssertEqual(DictationCleanupRoute.select(hasClaudeKey: true, proxyConfigured: true, hasGeminiKey: true), .claude)
        XCTAssertEqual(DictationCleanupRoute.select(hasClaudeKey: false, proxyConfigured: true, hasGeminiKey: true), .proxy)
        XCTAssertEqual(DictationCleanupRoute.select(hasClaudeKey: false, proxyConfigured: false, hasGeminiKey: false), .none)
        XCTAssertEqual(DictationCleanupRoute.select(config: Self.proxyConfig, hasClaudeKey: true, hasGeminiKey: false), .claude)
    }

    func testDictationUsesClaudeWhenKeyIsSetEvenWithProxy() async throws {
        let claude = RoutingSpyCleaner(result: "claude")
        let proxy = RoutingSpyCleaner(result: "proxy")
        let gemini = RoutingSpyCleaner(result: "gemini")
        let router = DictationCleanupRouter(
            config: Self.proxyConfig,
            claudeCleaner: claude,
            proxyCleaner: proxy,
            geminiCleaner: gemini
        )

        let cleaned = try await router.cleanup(Self.dictationRequest, timeout: 1)

        XCTAssertEqual(router.route, .claude)
        XCTAssertEqual(cleaned, "claude")
        XCTAssertEqual([claude.callCount, proxy.callCount, gemini.callCount], [1, 0, 0])
    }

    func testDictationUsesProxyWhenOnlyProxyIsConfigured() async throws {
        let proxy = RoutingSpyCleaner(result: "proxy")
        let router = DictationCleanupRouter(
            config: Self.proxyConfig,
            claudeCleaner: nil,
            proxyCleaner: proxy,
            geminiCleaner: nil
        )

        let cleaned = try await router.cleanup(Self.dictationRequest, timeout: 1)

        XCTAssertEqual(router.route, .proxy)
        XCTAssertEqual(cleaned, "proxy")
        XCTAssertEqual(proxy.callCount, 1)
    }

    func testDictationLeavesRawTextWithNeither() async {
        let proxy = RoutingSpyCleaner(result: "proxy")
        let router = DictationCleanupRouter(
            config: VertexAIConfig(projectID: ""),
            claudeCleaner: nil,
            proxyCleaner: proxy,
            geminiCleaner: nil
        )

        XCTAssertEqual(router.route, .none)
        do {
            _ = try await router.cleanup(Self.dictationRequest, timeout: 1)
            XCTFail("Expected notConfigured")
        } catch DictationCleanupError.notConfigured {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(proxy.callCount, 0)
    }

    func testClaudeDictationCleanerSendsCleanupPromptsDirectly() async throws {
        ClaudeAPIStub.setResponse(body: ClaudeAPIClientTests.messagesBody(text: "「これは接続テストです。」"))
        let request = Self.dictationRequest
        let builder = DictationCleanupPromptBuilder()
        let cleaner = ClaudeDictationCleaner(
            client: ClaudeAPIClient(apiKeyProvider: { "test-key" }, urlSession: ClaudeAPIClientTests.makeSession())
        )

        let cleaned = try await cleaner.cleanup(request, timeout: 2)

        XCTAssertEqual(cleaned, GeneratedReplySanitizer.sanitize("「これは接続テストです。」"))
        let recorded = try XCTUnwrap(ClaudeAPIStub.requests.first)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        let json = try ClaudeAPIClientTests.jsonBody(recorded.httpBody)
        XCTAssertEqual(json["system"] as? String, builder.systemInstruction(style: .light))
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, builder.userPrompt(for: request))
        XCTAssertEqual(json["max_tokens"] as? Int, DictationCleanupTokenBudget.maxOutputTokens(for: request.rawText))
        XCTAssertNil(json["temperature"])
    }

    func testClaudeDictationCleanerRejectsOverlongOutput() async {
        ClaudeAPIStub.setResponse(
            body: ClaudeAPIClientTests.messagesBody(text: String(repeating: "追加された文章です。", count: 20))
        )
        let cleaner = ClaudeDictationCleaner(
            client: ClaudeAPIClient(apiKeyProvider: { "test-key" }, urlSession: ClaudeAPIClientTests.makeSession())
        )
        do {
            _ = try await cleaner.cleanup(Self.dictationRequest, timeout: 2)
            XCTFail("Must reject output that grew far beyond the transcript")
        } catch DictationCleanupError.rejectedOutput {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private static var proxyConfig: VertexAIConfig {
        VertexAIConfig(
            projectID: "",
            proxyURLString: "https://proxy.invalid/v1/rewrite",
            proxyAuthToken: "test-only"
        )
    }

    private static let formRequest = FormFillRequest(
        appInfo: AppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 1),
        fields: [FormFieldSnapshot(index: 0, label: "お名前")],
        userProfile: UserProfile(displayName: "Example User")
    )

    private static let dictationRequest = DictationCleanupRequest(
        rawText: "えーと、これは接続テストです",
        appInfo: AppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: nil)
    )

    private func makePlanner(config: VertexAIConfig, claudeKey: String?) -> FormFillPlanner {
        FormFillPlanner(
            configProvider: { config },
            claudeAPIKeyProvider: { claudeKey },
            urlSession: ClaudeAPIClientTests.makeSession()
        )
    }
}

@MainActor
private final class RewriteSpies {
    private(set) var calls: [String] = []

    func makeRouter(config: VertexAIConfig, claudeKey: String?) -> RewriteRouter {
        RewriteRouter(
            configProvider: { config },
            claudeAPIKeyProvider: { claudeKey },
            tokenProvider: EnvironmentAccessTokenProvider(environment: [:]),
            claudeClient: SpyRewriter(name: "claude", source: .claudeAPI, owner: self),
            proxyClient: SpyRewriter(name: "proxy", source: .cloudRunProxy, owner: self),
            vertexClient: SpyRewriter(name: "vertex", source: .vertexAI, owner: self),
            previewRewriter: SpyRewriter(name: "preview", source: .localPreview, owner: self)
        )
    }

    func record(_ name: String) {
        calls.append(name)
    }
}

@MainActor
private final class SpyRewriter: TextRewriting {
    private let name: String
    private let source: RewriteSource
    private weak var owner: RewriteSpies?

    init(name: String, source: RewriteSource, owner: RewriteSpies) {
        self.name = name
        self.source = source
        self.owner = owner
    }

    func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        owner?.record(name)
        return RewriteResult(text: name, source: source)
    }
}

private final class RoutingSpyCleaner: DictationCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: String
    private var _callCount = 0

    init(result: String) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func cleanup(_ request: DictationCleanupRequest, timeout: TimeInterval) async throws -> String {
        lock.withLock { _callCount += 1 }
        return result
    }
}
