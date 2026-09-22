import Foundation

public final class RewriteRouter: TextRewriting {
    private let configProvider: () -> VertexAIConfig
    private let tokenProvider: AccessTokenProviding
    private let proxyClient: TextRewriting
    private let vertexClient: TextRewriting
    private let previewRewriter: TextRewriting

    public init(
        configProvider: @escaping () -> VertexAIConfig = { VertexAIConfig.load() },
        tokenProvider: AccessTokenProviding = EnvironmentAccessTokenProvider(),
        proxyClient: TextRewriting? = nil,
        vertexClient: TextRewriting? = nil,
        previewRewriter: TextRewriting = LocalPreviewRewriter()
    ) {
        self.configProvider = configProvider
        self.tokenProvider = tokenProvider
        self.proxyClient = proxyClient ?? CloudRunProxyClient(configProvider: configProvider)
        self.vertexClient = vertexClient ?? VertexAIClient(
            configProvider: configProvider,
            tokenProvider: tokenProvider
        )
        self.previewRewriter = previewRewriter
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
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
