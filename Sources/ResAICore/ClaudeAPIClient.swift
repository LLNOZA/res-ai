import Foundation

/// Errors carry only the HTTP status and a coarse classification. Response bodies, the key, and
/// prompt text are never stored here, so they cannot reach logs or the HUD.
public enum ClaudeAPIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case incompleteResponse(stopReason: String?)
    case emptyText
    case apiError(statusCode: Int)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Claude API key is not configured."
        case .invalidResponse:
            "Claude API returned an empty or invalid response."
        case let .incompleteResponse(stopReason):
            "Claude API returned incomplete output (\(stopReason ?? "unknown reason"))."
        case .emptyText:
            "Claude API returned no text."
        case let .apiError(statusCode):
            "Claude API request failed with HTTP \(statusCode) (\(Self.classification(for: statusCode)))."
        case .timeout:
            "Claude API request timed out."
        }
    }

    static func classification(for statusCode: Int) -> String {
        switch statusCode {
        case 400: "invalid request"
        case 401: "authentication"
        case 403: "permission"
        case 404: "not found"
        case 413: "request too large"
        case 429: "rate limited"
        case 500..<600: "server error"
        default: "unexpected status"
        }
    }
}

/// Calls `https://api.anthropic.com/v1/messages` directly with the user's own API key.
/// The model is fixed in code; sampling parameters are never sent because the model rejects them.
public final class ClaudeAPIClient: TextRewriting {
    public nonisolated static let model = "claude-haiku-5-5"
    public nonisolated static let anthropicVersion = "2023-06-01"
    public nonisolated static let defaultMaxTokens = 4096
    nonisolated static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    nonisolated static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!

    private let apiKeyProvider: () -> String?
    private let promptBuilder: RewritePromptBuilder
    private let urlSession: URLSession

    public init(
        apiKeyProvider: @escaping () -> String? = { ClaudeAPIKeyStore.load() },
        promptBuilder: RewritePromptBuilder = RewritePromptBuilder(),
        urlSession: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.promptBuilder = promptBuilder
        self.urlSession = urlSession ?? NetworkRequestSafety.session
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        let rawText = try await generateText(
            systemInstruction: promptBuilder.systemInstruction(),
            userPrompt: promptBuilder.userPrompt(for: request),
            maxTokens: Self.defaultMaxTokens,
            timeout: 20
        )
        let text = GeneratedReplySanitizer.sanitize(rawText)
        guard !text.isEmpty else {
            throw ClaudeAPIError.emptyText
        }

        return RewriteResult(text: text, source: .claudeAPI)
    }

    /// Sends one system + user prompt pair and returns the unsanitized text blocks.
    public func generateText(
        systemInstruction: String,
        userPrompt: String,
        maxTokens: Int = ClaudeAPIClient.defaultMaxTokens,
        timeout: TimeInterval
    ) async throws -> String {
        let urlRequest = try Self.makeMessagesRequest(
            apiKey: requireAPIKey(),
            systemInstruction: systemInstruction,
            userPrompt: userPrompt,
            maxTokens: maxTokens,
            timeout: timeout
        )
        let (data, statusCode) = try await send(urlRequest, timeout: timeout)
        guard (200..<300).contains(statusCode) else {
            throw ClaudeAPIError.apiError(statusCode: statusCode)
        }
        return try Self.parseMessagesResponse(data)
    }

    /// Lists models (`GET /v1/models`) to confirm the key works without consuming tokens.
    public func verifyAPIKey(timeout: TimeInterval = 8) async throws {
        var urlRequest = URLRequest(url: Self.modelsURL)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(try requireAPIKey(), forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let (_, statusCode) = try await send(urlRequest, timeout: timeout)
        guard statusCode == 200 else {
            throw ClaudeAPIError.apiError(statusCode: statusCode)
        }
    }

    nonisolated static func makeMessagesRequest(
        apiKey: String,
        systemInstruction: String,
        userPrompt: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: messagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // temperature / top_p / top_k are intentionally absent: the model returns HTTP 400 for them.
        urlRequest.httpBody = try JSONEncoder.claude.encode(
            ClaudeMessagesRequest(
                model: model,
                maxTokens: maxTokens,
                system: systemInstruction,
                messages: [ClaudeMessage(role: "user", content: userPrompt)]
            )
        )
        return urlRequest
    }

    nonisolated static func parseMessagesResponse(_ data: Data) throws -> String {
        let decoded: ClaudeMessagesResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeMessagesResponse.self, from: data)
        } catch {
            throw ClaudeAPIError.invalidResponse
        }
        guard decoded.stopReason == "end_turn" || decoded.stopReason == "stop_sequence" else {
            throw ClaudeAPIError.incompleteResponse(stopReason: decoded.stopReason)
        }
        // Thinking and other non-text blocks are dropped; only the answer text is used.
        let text = (decoded.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ClaudeAPIError.emptyText
        }
        return text
    }

    private func send(_ urlRequest: URLRequest, timeout: TimeInterval) async throws -> (Data, Int) {
        let session = urlSession
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await NetworkRequestSafety.runWithTimeout(
                timeout,
                timeoutError: ClaudeAPIError.timeout
            ) {
                try await session.data(for: urlRequest)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw ClaudeAPIError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }
        return (data, httpResponse.statusCode)
    }

    private func requireAPIKey() throws -> String {
        let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            throw ClaudeAPIError.missingAPIKey
        }
        return key
    }
}

/// The user's Claude API key lives only in the Keychain. It is never written to UserDefaults,
/// logs, or the app bundle.
public enum ClaudeAPIKeyStore {
    public static let account = "anthropic.apiKey"

    public static func load(secretStore: any SecretStringStoring = KeychainStore()) -> String? {
        let value = (try? secretStore.string(for: account))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    public static func hasKey(secretStore: any SecretStringStoring = KeychainStore()) -> Bool {
        load(secretStore: secretStore) != nil
    }

    /// Saving an empty string deletes the stored key.
    public static func save(_ key: String, secretStore: any SecretStringStoring = KeychainStore()) throws {
        try secretStore.setString(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
    }

    public static func delete(secretStore: any SecretStringStoring = KeychainStore()) throws {
        try secretStore.setString("", for: account)
    }
}

/// Which backend the AI features use, in priority order:
/// Claude API key → direct Claude API; otherwise a configured proxy; otherwise local preview.
public enum AIBackendRoute: Equatable, Sendable {
    case claudeAPI
    case proxy
    case preview

    public static func select(hasClaudeKey: Bool, proxyConfigured: Bool) -> AIBackendRoute {
        if hasClaudeKey {
            return .claudeAPI
        }
        return proxyConfigured ? .proxy : .preview
    }

    public static func select(hasClaudeKey: Bool, config: VertexAIConfig) -> AIBackendRoute {
        select(hasClaudeKey: hasClaudeKey, proxyConfigured: config.proxyURL != nil)
    }

    public var displayName: String {
        switch self {
        case .claudeAPI: "Claude API 直接"
        case .proxy: "中継（AIプロキシ）"
        case .preview: "プレビュー（AI未接続）"
        }
    }
}

private struct ClaudeMessagesRequest: Encodable, Equatable {
    var model: String
    var maxTokens: Int
    var system: String
    var messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct ClaudeMessage: Encodable, Equatable {
    var role: String
    var content: String
}

private struct ClaudeMessagesResponse: Decodable {
    var content: [Block]?
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    struct Block: Decodable {
        var type: String
        var text: String?
    }
}

private extension JSONEncoder {
    static var claude: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
