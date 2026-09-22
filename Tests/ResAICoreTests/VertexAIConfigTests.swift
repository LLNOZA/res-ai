import XCTest
@testable import ResAICore

final class VertexAIConfigTests: XCTestCase {
    func testLoadsConfigFromEnvironment() {
        let config = VertexAIConfig.load(environment: [
            "RESAI_VERTEX_PROJECT_ID": "project-a",
            "RESAI_VERTEX_LOCATION": "us-central1",
            "RESAI_VERTEX_MODEL": "gemini-test",
            "RESAI_VERTEX_REGIONAL_ENDPOINT": "true",
            "RESAI_VERTEX_PROXY_URL": "https://proxy.example.test/v1/rewrite",
            "RESAI_PROXY_SHARED_SECRET": "fixture-token"
        ], defaults: UserDefaults(suiteName: UUID().uuidString)!, secretStore: MemorySecretStore())

        XCTAssertEqual(config.projectID, "project-a")
        XCTAssertEqual(config.location, "us-central1")
        XCTAssertEqual(config.model, "gemini-test")
        XCTAssertTrue(config.useRegionalEndpoint)
        XCTAssertEqual(config.proxyURL?.absoluteString, "https://proxy.example.test/v1/rewrite")
        XCTAssertEqual(config.proxyAuthToken, "fixture-token")
        XCTAssertEqual(
            config.endpointURL.absoluteString,
            "https://us-central1-aiplatform.googleapis.com/v1/projects/project-a/locations/us-central1/publishers/google/models/gemini-test:generateContent"
        )
    }

    func testLoadsSafeBundledDefaultsWhenLocalDefaultsAreEmpty() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VertexAIConfigBundledDefaultsTests"))
        defaults.removePersistentDomain(forName: "VertexAIConfigBundledDefaultsTests")

        let config = VertexAIConfig.load(environment: [:], defaults: defaults, secretStore: MemorySecretStore())

        XCTAssertTrue(config.projectID.isEmpty)
        XCTAssertEqual(config.location, "global")
        XCTAssertEqual(config.model, "gemini-3.5-flash")
        XCTAssertNil(config.proxyURL)
        XCTAssertTrue(config.proxyAuthToken.isEmpty, "Never embed a shared credential in the app")
        XCTAssertFalse(config.isConfigured)
    }

    func testBundledProxyCanBeDisabledForDirectVertexDevelopment() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VertexAIConfigDisableBundledProxyTests"))
        defaults.removePersistentDomain(forName: "VertexAIConfigDisableBundledProxyTests")

        let config = VertexAIConfig.load(
            environment: ["RESAI_DISABLE_BUNDLED_PROXY": "1"],
            defaults: defaults,
            secretStore: MemorySecretStore()
        )

        XCTAssertNil(config.proxyURL)
        XCTAssertTrue(config.proxyAuthToken.isEmpty)
        XCTAssertTrue(config.projectID.isEmpty)
    }

    func testLegacyTokenMigratesOnlyAfterSuccessfulKeychainWrite() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("legacy-test-token", forKey: VertexAIConfig.DefaultsKey.proxyAuthToken)
        let store = MemorySecretStore()
        store.failWrites = true
        XCTAssertEqual(VertexAIConfig.load(environment: [:], defaults: defaults, secretStore: store).proxyAuthToken, "legacy-test-token")
        XCTAssertNotNil(defaults.string(forKey: VertexAIConfig.DefaultsKey.proxyAuthToken))
        store.failWrites = false
        XCTAssertEqual(VertexAIConfig.load(environment: [:], defaults: defaults, secretStore: store).proxyAuthToken, "legacy-test-token")
        XCTAssertEqual(store.value, "legacy-test-token")
        XCTAssertNil(defaults.string(forKey: VertexAIConfig.DefaultsKey.proxyAuthToken))
    }

    func testSaveDoesNotPersistSecretInDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemorySecretStore()
        let config = VertexAIConfig(projectID: "test", proxyAuthToken: "test-token")
        try config.save(to: defaults, secretStore: store)
        XCTAssertEqual(store.value, "test-token")
        XCTAssertNil(defaults.string(forKey: VertexAIConfig.DefaultsKey.proxyAuthToken))
    }
}

private final class MemorySecretStore: SecretStringStoring {
    var value: String?
    var failWrites = false
    func string(for account: String) throws -> String? { value }
    func setString(_ value: String, for account: String) throws {
        if failWrites { throw KeychainStoreError.unexpectedStatus(-1) }
        self.value = value.isEmpty ? nil : value
    }
}
