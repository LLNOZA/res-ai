import Foundation

public enum GeminiAPIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    /// The request succeeded but no usable text came back (blocked, MAX_TOKENS, thought-only, ...).
    case emptyText(finishReason: String?)
    /// The cleaner rejected the model output as unsafe to swap in.
    case rejectedOutput(reason: String)
    /// The model returned a partial/blocked response that must never replace user text.
    case incompleteText(finishReason: String?)
    case apiError(statusCode: Int, body: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Gemini API key is not configured."
        case .invalidResponse:
            "Gemini API returned an empty or invalid response."
        case let .emptyText(finishReason):
            "Gemini API returned no text (finishReason=\(finishReason ?? "nil"))."
        case let .rejectedOutput(reason):
            "Gemini output rejected: \(NetworkRequestSafety.safeBody(reason, limit: 160))."
        case let .incompleteText(finishReason):
            "Gemini API returned incomplete output (\(finishReason ?? "unknown reason"))."
        case let .apiError(statusCode, _):
            "Gemini API request failed with HTTP \(statusCode)."
        case .timeout:
            "Gemini API request timed out."
        }
    }
}

public struct GeminiTextRequest: Equatable, Sendable {
    public var systemInstruction: String
    public var userPrompt: String
    public var maxOutputTokens: Int
    public var temperature: Double

    public init(
        systemInstruction: String,
        userPrompt: String,
        maxOutputTokens: Int,
        temperature: Double
    ) {
        self.systemInstruction = systemInstruction
        self.userPrompt = userPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

public final class GeminiAPIClient: Sendable {
    public static let defaultRequestTimeout: TimeInterval = 6

    private let apiKeyProvider: @Sendable () -> String?
    private let model: @Sendable () -> String
    private let urlSession: URLSession

    public var sessionConfiguration: URLSessionConfiguration {
        urlSession.configuration
    }

    public static func makeDefaultSession(requestTimeout: TimeInterval = defaultRequestTimeout) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(requestTimeout, 1) * 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private static let defaultSession: URLSession = makeDefaultSession()

    public init(
        apiKeyProvider: @Sendable @escaping () -> String?,
        model: @Sendable @escaping () -> String,
        urlSession: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.model = model
        self.urlSession = urlSession ?? Self.defaultSession
    }

    public func generateText(_ request: GeminiTextRequest, timeout: TimeInterval) async throws -> String {
        try await NetworkRequestSafety.runWithTimeout(timeout, timeoutError: GeminiAPIError.timeout) {
            try await self.generateTextWithRetry(request, timeout: timeout)
        }
    }

    /// Cheap GET of model metadata so TLS is warmed before cleanup. Ignores the result.
    public func prewarmConnection() async {
        do {
            let apiKey = try requireAPIKey()
            guard let url = modelMetadataURL(), NetworkRequestSafety.isAllowedURL(url) else { return }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.timeoutInterval = 3
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            _ = try await urlSession.data(for: urlRequest)
        } catch {
            // Fire-and-forget: never surface handshake failures.
        }
    }

    public func listModels(timeout: TimeInterval) async throws -> [String] {
        try await NetworkRequestSafety.runWithTimeout(timeout, timeoutError: GeminiAPIError.timeout) {
            try await self.sendListModels(timeout: timeout)
        }
    }

    private func generateTextWithRetry(_ request: GeminiTextRequest, timeout: TimeInterval) async throws -> String {
        do {
            return try await sendGenerate(request, includeThinking: true, timeout: timeout)
        } catch let error as GeminiAPIError {
            guard case let .apiError(statusCode, body) = error,
                  statusCode == 400,
                  body.lowercased().contains("thinking")
            else {
                throw error
            }
            return try await sendGenerate(request, includeThinking: false, timeout: timeout)
        }
    }

    private func sendGenerate(
        _ request: GeminiTextRequest,
        includeThinking: Bool,
        timeout: TimeInterval
    ) async throws -> String {
        let apiKey = try requireAPIKey()
        guard let url = generateContentURL() else {
            throw GeminiAPIError.invalidResponse
        }
        guard NetworkRequestSafety.isAllowedURL(url) else {
            throw GeminiAPIError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder.gemini.encode(
            GeminiGenerateContentRequest(
                systemInstruction: GeminiContent(parts: [GeminiPart(text: request.systemInstruction)]),
                contents: [
                    GeminiContent(role: "user", parts: [GeminiPart(text: request.userPrompt)])
                ],
                generationConfig: GeminiGenerationConfig(
                    temperature: request.temperature,
                    maxOutputTokens: request.maxOutputTokens,
                    thinkingConfig: includeThinking ? GeminiThinkingConfig(thinkingBudget: 0) : nil
                )
            )
        )

        let result = try await send(urlRequest)
        guard (200..<300).contains(result.statusCode) else {
            throw GeminiAPIError.apiError(statusCode: result.statusCode, body: result.bodyText)
        }

        let decoded: GeminiGenerateContentResponse
        do {
            decoded = try JSONDecoder.gemini.decode(GeminiGenerateContentResponse.self, from: result.data)
        } catch {
            throw GeminiAPIError.invalidResponse
        }

        guard decoded.finishReason?.uppercased() == "STOP" else {
            throw GeminiAPIError.incompleteText(finishReason: decoded.finishReason)
        }
        guard let text = decoded.joinedText, !text.isEmpty else {
            throw GeminiAPIError.emptyText(finishReason: decoded.finishReason)
        }
        return text
    }

    private func sendListModels(timeout: TimeInterval) async throws -> [String] {
        let apiKey = try requireAPIKey()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/models"
        guard let url = components.url else {
            throw GeminiAPIError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let result = try await send(urlRequest)
        guard (200..<300).contains(result.statusCode) else {
            throw GeminiAPIError.apiError(statusCode: result.statusCode, body: result.bodyText)
        }

        let decoded: GeminiModelListResponse
        do {
            decoded = try JSONDecoder.gemini.decode(GeminiModelListResponse.self, from: result.data)
        } catch {
            throw GeminiAPIError.invalidResponse
        }

        return (decoded.models ?? []).compactMap { model in
            guard let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            if name.hasPrefix("models/") {
                return String(name.dropFirst("models/".count))
            }
            return name
        }
    }

    private func send(_ urlRequest: URLRequest) async throws -> GeminiHTTPResult {
        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiAPIError.invalidResponse
            }
            return GeminiHTTPResult(statusCode: httpResponse.statusCode, data: data)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiAPIError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as GeminiAPIError {
            throw error
        }
    }

    private func requireAPIKey() throws -> String {
        let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            throw GeminiAPIError.missingAPIKey
        }
        return key
    }

    private func generateContentURL() -> URL? {
        modelEndpointURL(suffix: ":generateContent")
    }

    private func modelMetadataURL() -> URL? {
        modelEndpointURL(suffix: "")
    }

    private func modelEndpointURL(suffix: String) -> URL? {
        var modelName = model().trimmingCharacters(in: .whitespacesAndNewlines)
        if modelName.hasPrefix("models/") {
            modelName = String(modelName.dropFirst("models/".count))
        }
        let encoded = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded)\(suffix)")
    }
}

private struct GeminiHTTPResult: Sendable {
    var statusCode: Int
    var data: Data

    var bodyText: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

private struct GeminiGenerateContentRequest: Encodable, Equatable {
    var systemInstruction: GeminiContent
    var contents: [GeminiContent]
    var generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable, Equatable {
    var role: String?
    var parts: [GeminiPart]
}

private struct GeminiPart: Encodable, Equatable {
    var text: String
}

private struct GeminiGenerationConfig: Encodable, Equatable {
    var temperature: Double
    var maxOutputTokens: Int
    var thinkingConfig: GeminiThinkingConfig?
}

private struct GeminiThinkingConfig: Encodable, Equatable {
    var thinkingBudget: Int
}

private struct GeminiGenerateContentResponse: Decodable, Equatable {
    var candidates: [Candidate]?

    var joinedText: String? {
        guard let parts = candidates?.first?.content?.parts else {
            return nil
        }
        // Thinking models can return `thought: true` parts alongside the answer; never surface those.
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        return text
    }

    var finishReason: String? {
        candidates?.first?.finishReason ?? promptFeedback?.blockReason
    }

    var promptFeedback: PromptFeedback?

    struct Candidate: Decodable, Equatable {
        var content: Content?
        var finishReason: String?
    }

    struct Content: Decodable, Equatable {
        var parts: [Part]?
    }

    struct Part: Decodable, Equatable {
        var text: String?
        var thought: Bool?
    }

    struct PromptFeedback: Decodable, Equatable {
        var blockReason: String?
    }
}

private struct GeminiModelListResponse: Decodable {
    var models: [Model]?

    struct Model: Decodable {
        var name: String?
    }
}

private extension JSONEncoder {
    static var gemini: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var gemini: JSONDecoder {
        JSONDecoder()
    }
}
