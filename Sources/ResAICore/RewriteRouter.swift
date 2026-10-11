import Foundation

public final class RewriteRouter: TextRewriting {
    private let configProvider: () -> VertexAIConfig
    private let claudeAPIKeyProvider: () -> String?
    private let tokenProvider: AccessTokenProviding
    private let claudeClient: TextRewriting
    private let proxyClient: TextRewriting
    private let vertexClient: TextRewriting
    private let previewRewriter: TextRewriting

    public init(
        configProvider: @escaping () -> VertexAIConfig = { VertexAIConfig.load() },
        claudeAPIKeyProvider: @escaping () -> String? = { ClaudeAPIKeyStore.load() },
        tokenProvider: AccessTokenProviding = EnvironmentAccessTokenProvider(),
        claudeClient: TextRewriting? = nil,
        proxyClient: TextRewriting? = nil,
        vertexClient: TextRewriting? = nil,
        previewRewriter: TextRewriting = LocalPreviewRewriter()
    ) {
        self.configProvider = configProvider
        self.claudeAPIKeyProvider = claudeAPIKeyProvider
        self.tokenProvider = tokenProvider
        self.claudeClient = claudeClient ?? ClaudeAPIClient(apiKeyProvider: claudeAPIKeyProvider)
        self.proxyClient = proxyClient ?? CloudRunProxyClient(configProvider: configProvider)
        self.vertexClient = vertexClient ?? VertexAIClient(
            configProvider: configProvider,
            tokenProvider: tokenProvider
        )
        self.previewRewriter = previewRewriter
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        // A user's own Claude API key always wins; the proxy stays for the migration period.
        let claudeKey = claudeAPIKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !claudeKey.isEmpty {
            return try await claudeClient.rewrite(request)
        }

        let config = configProvider()
        if config.proxyURL != nil {
            return try await proxyClient.rewrite(request)
        }

        guard config.isConfigured else {
            return try await previewRewriter.rewrite(request)
        }

        do {
            _ = try tokenProvider.accessToken()
        } catch {
            return try await previewRewriter.rewrite(request)
        }

        return try await vertexClient.rewrite(request)
    }
}
