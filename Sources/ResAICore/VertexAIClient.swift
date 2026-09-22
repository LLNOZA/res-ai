import Foundation

public enum VertexAIError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case incompleteResponse(finishReason: String?)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Vertex AI project, location, or model is not configured."
        case .invalidResponse:
            "Vertex AI returned an empty or invalid response."
        case let .apiError(statusCode, _):
            "Vertex AI request failed with HTTP \(statusCode)."
        case let .incompleteResponse(finishReason):
            "Vertex AI returned incomplete output (\(finishReason ?? "unknown reason"))."
        case .timeout:
            "Vertex AI request timed out."
        }
    }
}

@MainActor
public protocol TextRewriting {
    func rewrite(_ request: RewriteRequest) async throws -> RewriteResult
}

public final class VertexAIClient: TextRewriting {
    private let configProvider: () -> VertexAIConfig
    private let tokenProvider: AccessTokenProviding
    private let promptBuilder: RewritePromptBuilder
    private let urlSession: URLSession

    public init(
        configProvider: @escaping () -> VertexAIConfig = { VertexAIConfig.load() },
        tokenProvider: AccessTokenProviding = EnvironmentAccessTokenProvider(),
        promptBuilder: RewritePromptBuilder = RewritePromptBuilder(),
        urlSession: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.tokenProvider = tokenProvider
        self.promptBuilder = promptBuilder
        self.urlSession = urlSession ?? NetworkRequestSafety.session
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        let config = configProvider()
        guard config.isConfigured else {
            throw VertexAIError.missingConfiguration
        }

        let accessToken = try tokenProvider.accessToken()
        let apiRequest = VertexGenerateContentRequest(
            systemInstruction: VertexContent(parts: [
                VertexPart(text: promptBuilder.systemInstruction())
            ]),
            contents: [
                VertexContent(role: "user", parts: [
                    VertexPart(text: promptBuilder.userPrompt(for: request))
                ])
            ],
            generationConfig: VertexGenerationConfig(
                temperature: 0.25,
                maxOutputTokens: 4096
            )
        )

        guard NetworkRequestSafety.isAllowedURL(config.endpointURL) else {
            throw VertexAIError.invalidResponse
        }
        var urlRequest = URLRequest(url: config.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder.vertex.encode(apiRequest)
        let requestForTransport = urlRequest
        let session = urlSession

        let (data, response) = try await NetworkRequestSafety.runWithTimeout(
            20,
            timeoutError: VertexAIError.timeout
        ) {
            try await session.data(for: requestForTransport)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexAIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VertexAIError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        let decoded: VertexGenerateContentResponse
        do {
            decoded = try JSONDecoder.vertex.decode(VertexGenerateContentResponse.self, from: data)
        } catch {
            throw VertexAIError.invalidResponse
        }
        guard decoded.finishReason?.uppercased() == "STOP" else {
            throw VertexAIError.incompleteResponse(finishReason: decoded.finishReason)
        }
        guard let rawText = decoded.primaryText else {
            throw VertexAIError.invalidResponse
        }

        let text = GeneratedReplySanitizer.sanitize(rawText)
        guard !text.isEmpty else {
            throw VertexAIError.invalidResponse
        }

        return RewriteResult(text: text, source: .vertexAI)
    }
}

public struct VertexGenerateContentRequest: Encodable, Equatable {
    public var systemInstruction: VertexContent
    public var contents: [VertexContent]
    public var generationConfig: VertexGenerationConfig

    public init(
        systemInstruction: VertexContent,
        contents: [VertexContent],
        generationConfig: VertexGenerationConfig
    ) {
        self.systemInstruction = systemInstruction
        self.contents = contents
        self.generationConfig = generationConfig
    }
}

public struct VertexContent: Codable, Equatable {
    public var role: String?
    public var parts: [VertexPart]

    public init(role: String? = nil, parts: [VertexPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct VertexPart: Codable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct VertexGenerationConfig: Encodable, Equatable {
    public var temperature: Double
    public var maxOutputTokens: Int

    public init(temperature: Double, maxOutputTokens: Int) {
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct VertexGenerateContentResponse: Decodable, Equatable {
    public var candidates: [Candidate]?

    public var primaryText: String? {
        candidates?.first?.content?.parts?
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    public var finishReason: String? {
        candidates?.first?.finishReason
    }

    public struct Candidate: Decodable, Equatable {
        public var content: VertexResponseContent?
        public var finishReason: String?
    }

    public struct VertexResponseContent: Decodable, Equatable {
        public var parts: [VertexResponsePart]?
    }

    public struct VertexResponsePart: Decodable, Equatable {
        public var text: String?
        public var thought: Bool?
    }
}

private extension JSONEncoder {
    static var vertex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var vertex: JSONDecoder {
        JSONDecoder()
    }
}
