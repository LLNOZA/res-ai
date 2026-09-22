import Foundation

public enum CloudRunProxyError: LocalizedError {
    case missingProxyURL
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case incompleteResponse(finishReason: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingProxyURL:
            "Cloud Run proxy URL is not configured."
        case .invalidResponse:
            "Cloud Run proxy returned an empty or invalid response."
        case let .apiError(statusCode, _):
            "Cloud Run proxy request failed with HTTP \(statusCode)."
        case let .incompleteResponse(finishReason):
            "Cloud Run proxy returned incomplete output (\(finishReason))."
        case .timeout:
            "Cloud Run proxy request timed out."
        }
    }
}

public final class CloudRunProxyClient: TextRewriting {
    private let configProvider: () -> VertexAIConfig
    private let promptBuilder: RewritePromptBuilder
    private let urlSession: URLSession

    public init(
        configProvider: @escaping () -> VertexAIConfig = { VertexAIConfig.load() },
        promptBuilder: RewritePromptBuilder = RewritePromptBuilder(),
        urlSession: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.promptBuilder = promptBuilder
        self.urlSession = urlSession ?? NetworkRequestSafety.session
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        let config = configProvider()
        guard let proxyURL = config.proxyURL else {
            throw CloudRunProxyError.missingProxyURL
        }
        guard NetworkRequestSafety.isAllowedURL(proxyURL) else {
            throw CloudRunProxyError.invalidResponse
        }

        let payload = CloudRunProxyRewriteRequest(
            systemInstruction: promptBuilder.systemInstruction(),
            userPrompt: promptBuilder.userPrompt(for: request)
        )

        var urlRequest = URLRequest(url: proxyURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let proxyAuthToken = config.proxyAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxyAuthToken.isEmpty {
            urlRequest.setValue(proxyAuthToken, forHTTPHeaderField: "X-ResAI-Proxy-Key")
        }

        urlRequest.httpBody = try JSONEncoder.resaiProxy.encode(payload)
        let requestForTransport = urlRequest
        let session = urlSession

        let (data, response) = try await NetworkRequestSafety.runWithTimeout(
            20,
            timeoutError: CloudRunProxyError.timeout
        ) {
            try await session.data(for: requestForTransport)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudRunProxyError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudRunProxyError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        let decoded: CloudRunProxyRewriteResponse
        do {
            decoded = try JSONDecoder.resaiProxy.decode(CloudRunProxyRewriteResponse.self, from: data)
        } catch {
            throw CloudRunProxyError.invalidResponse
        }
        if let finishReason = decoded.finishReason,
           finishReason.uppercased() != "STOP" {
            throw CloudRunProxyError.incompleteResponse(finishReason: finishReason)
        }
        let text = GeneratedReplySanitizer.sanitize(decoded.text)
        guard !text.isEmpty else {
            throw CloudRunProxyError.invalidResponse
        }

        return RewriteResult(text: text, source: .cloudRunProxy)
    }
}

public struct CloudRunProxyRewriteRequest: Encodable, Equatable {
    public var systemInstruction: String
    public var userPrompt: String

    public init(
        systemInstruction: String,
        userPrompt: String
    ) {
        self.systemInstruction = systemInstruction
        self.userPrompt = userPrompt
    }
}

public struct CloudRunProxyRewriteResponse: Decodable, Equatable {
    public var text: String
    public var model: String?
    public var location: String?
    /// Older deployed proxies omit this field. Nil remains compatible; an explicit non-STOP
    /// reason is rejected so partial text cannot replace user input.
    public var finishReason: String?
}

private extension JSONEncoder {
    static var resaiProxy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var resaiProxy: JSONDecoder {
        JSONDecoder()
    }
}
