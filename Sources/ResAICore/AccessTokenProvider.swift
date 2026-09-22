import Foundation

public enum AccessTokenError: LocalizedError {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Vertex AI access token is not configured yet."
        }
    }
}

public protocol AccessTokenProviding {
    func accessToken() throws -> String
}

public struct EnvironmentAccessTokenProvider: AccessTokenProviding {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func accessToken() throws -> String {
        let token = [
            environment["VERTEX_AI_ACCESS_TOKEN"],
            environment["GOOGLE_OAUTH_ACCESS_TOKEN"],
            environment["RESAI_VERTEX_ACCESS_TOKEN"]
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        guard let token else {
            throw AccessTokenError.missingToken
        }

        return token
    }
}
