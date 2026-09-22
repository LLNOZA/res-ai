import Foundation

public struct VertexAIConfig: Equatable {
    public var projectID: String
    public var location: String
    public var model: String
    public var useRegionalEndpoint: Bool
    public var proxyURLString: String
    public var proxyAuthToken: String

    public init(
        projectID: String,
        location: String = "global",
        model: String = "gemini-3.5-flash",
        useRegionalEndpoint: Bool = false,
        proxyURLString: String = "",
        proxyAuthToken: String = ""
    ) {
        self.projectID = projectID
        self.location = location
        self.model = model
        self.useRegionalEndpoint = useRegionalEndpoint
        self.proxyURLString = proxyURLString
        self.proxyAuthToken = proxyAuthToken
    }

    public var isConfigured: Bool {
        !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var endpointURL: URL {
        let escape: (String) -> String = { segment in
            segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
        }
        let path = "/v1/projects/\(escape(projectID))/locations/\(escape(location))/publishers/google/models/\(escape(model)):generateContent"
        let host: String

        if useRegionalEndpoint, location != "global" {
            host = "\(location)-aiplatform.googleapis.com"
        } else {
            host = "aiplatform.googleapis.com"
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        // Fallback is a constant literal that can never be nil, so this stays crash-free
        // even if projectID/location/model ever contain unexpected characters.
        return components.url ?? URL(string: "https://aiplatform.googleapis.com")!
    }

    public var proxyURL: URL? {
        let trimmed = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(string: trimmed)
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        secretStore: any SecretStringStoring = KeychainStore()
    ) -> VertexAIConfig {
        let bundledProxyEnabled = !["1", "true", "yes"].contains(
            environment["RESAI_DISABLE_BUNDLED_PROXY"]?.lowercased() ?? ""
        )
        let projectID = firstNonEmpty([
            environment["RESAI_VERTEX_PROJECT_ID"],
            environment["GOOGLE_CLOUD_PROJECT"],
            environment["GCLOUD_PROJECT"],
            defaults.string(forKey: DefaultsKey.projectID)
        ]) ?? BundledDefaults.projectID

        let location = firstNonEmpty([
            environment["RESAI_VERTEX_LOCATION"],
            defaults.string(forKey: DefaultsKey.location)
        ]) ?? BundledDefaults.location

        let model = firstNonEmpty([
            environment["RESAI_VERTEX_MODEL"],
            defaults.string(forKey: DefaultsKey.model)
        ]) ?? BundledDefaults.model

        let regional = firstNonEmpty([
            environment["RESAI_VERTEX_REGIONAL_ENDPOINT"],
            defaults.string(forKey: DefaultsKey.regionalEndpoint)
        ]).map { value in
            ["1", "true", "yes"].contains(value.lowercased())
        } ?? false

        let proxyURLString = firstNonEmpty([
            environment["RESAI_VERTEX_PROXY_URL"],
            environment["RESAI_PROXY_URL"],
            defaults.string(forKey: DefaultsKey.proxyURL)
        ]) ?? (bundledProxyEnabled ? BundledDefaults.proxyURLString : "")

        // Migrate only credentials explicitly stored by an existing installation.
        // Never delete the legacy value unless Keychain accepted the migration.
        let legacyToken = defaults.string(forKey: DefaultsKey.proxyAuthToken)
        var storedToken = try? secretStore.string(for: proxyTokenAccount)
        if let legacyToken, !legacyToken.isEmpty {
            do {
                try secretStore.setString(legacyToken, for: proxyTokenAccount)
                defaults.removeObject(forKey: DefaultsKey.proxyAuthToken)
                storedToken = legacyToken
            } catch {
                storedToken = legacyToken
            }
        }
        let proxyAuthToken = firstNonEmpty([
            environment["RESAI_PROXY_SHARED_SECRET"],
            environment["RESAI_PROXY_AUTH_TOKEN"],
            storedToken
        ]) ?? ""

        return VertexAIConfig(
            projectID: projectID,
            location: location,
            model: model,
            useRegionalEndpoint: regional,
            proxyURLString: proxyURLString,
            proxyAuthToken: proxyAuthToken
        )
    }

    public static let proxyTokenAccount = "vertex.proxyAuthToken"

    public func save(to defaults: UserDefaults = .standard, secretStore: any SecretStringStoring = KeychainStore()) throws {
        try secretStore.setString(proxyAuthToken, for: Self.proxyTokenAccount)
        defaults.removeObject(forKey: DefaultsKey.proxyAuthToken)
        defaults.set(projectID, forKey: DefaultsKey.projectID)
        defaults.set(location, forKey: DefaultsKey.location)
        defaults.set(model, forKey: DefaultsKey.model)
        defaults.set(useRegionalEndpoint ? "true" : "false", forKey: DefaultsKey.regionalEndpoint)
        defaults.set(proxyURLString, forKey: DefaultsKey.proxyURL)
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    public enum DefaultsKey {
        public static let projectID = "vertex.projectID"
        public static let location = "vertex.location"
        public static let model = "vertex.model"
        public static let regionalEndpoint = "vertex.regionalEndpoint"
        public static let proxyURL = "vertex.proxyURL"
        public static let proxyAuthToken = "vertex.proxyAuthToken"
    }

    enum BundledDefaults {
        // Public builds must not contain a deployer's project or proxy endpoint.
        // A user or deployment environment must provide these values explicitly.
        static let projectID = ""
        static let location = "global"
        static let model = "gemini-3.5-flash"
        static let proxyURLString = ""
    }
}
