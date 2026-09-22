import XCTest
@testable import ResAICore

final class UserProfileTests: XCTestCase {
    func testEmptyProfileProducesMissingProfileMarker() {
        XCTAssertTrue(UserProfile().isEmpty)
        XCTAssertEqual(UserProfile().promptText(), "(プロフィールなし)")
    }

    func testPromptTextNormalizesAndLimitsFields() {
        let profile = UserProfile(
            displayName: "  Example User  ",
            companyName: "Sample Organization",
            role: "Builder\nPM",
            email: "user@example.test",
            background: "",
            serviceDescription: "AI tools",
            writingStyle: String(repeating: "短", count: 430),
            preferredPhrases: "ありがとうございます",
            avoidedPhrases: "承知いたしました"
        )

        let text = profile.promptText(maxFieldCharacters: 20)

        XCTAssertTrue(text.contains("名前: Example User"))
        XCTAssertTrue(text.contains("会社・組織: Sample Organization"))
        XCTAssertTrue(text.contains("役割・肩書き: Builder PM"))
        XCTAssertTrue(text.contains("サービス・事業説明: AI tools"))
        XCTAssertTrue(text.contains("文体: \(String(repeating: "短", count: 20))..."))
        XCTAssertTrue(text.contains("よく使う言い回し: ありがとうございます"))
        XCTAssertTrue(text.contains("避けたい言い回し: 承知いたしました"))
        XCTAssertFalse(text.contains("user@example.test"))
    }

    func testFormFillPromptIncludesContactFields() {
        let profile = UserProfile(
            displayName: "Example User",
            companyName: "Sample Organization",
            role: "Builder",
            email: "user@example.test",
            phone: "000-0000-0000",
            website: "https://example.test",
            address: "Sample City 1-2-3",
            socialURL: "https://social.example.test/sample-user",
            formFillNotes: "AI導入相談に関心があります"
        )

        let text = profile.formFillPromptText()

        XCTAssertTrue(text.contains("user@example.test"))
        XCTAssertTrue(text.contains("000-0000-0000"))
        XCTAssertTrue(text.contains("https://example.test"))
        XCTAssertTrue(text.contains("AI導入相談に関心があります"))
    }

    func testProfileCodableRoundTrip() throws {
        let profile = UserProfile(
            displayName: "Example User",
            companyName: "Sample Organization",
            role: "Builder",
            email: "user@example.test",
            background: "AI product",
            formFillNotes: "AIフォーム回答",
            writingStyle: "短め",
            preferredPhrases: "助かります",
            avoidedPhrases: "承知いたしました"
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }

    func testProfileDecodesOlderJSONWithMissingFormFields() throws {
        let data = """
        {
          "displayName": "Example User",
          "role": "Builder",
          "background": "AI product",
          "writingStyle": "短め",
          "preferredPhrases": "助かります",
          "avoidedPhrases": "承知いたしました"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)

        XCTAssertEqual(decoded.displayName, "Example User")
        XCTAssertEqual(decoded.role, "Builder")
        XCTAssertEqual(decoded.email, "")
        XCTAssertEqual(decoded.companyName, "")
    }

    func testProfileSaveAndLoad() {
        let suiteName = "UserProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = UserProfile(
            displayName: "Example User",
            companyName: "Sample Organization",
            role: "PM",
            email: "user@example.test",
            background: "BtoB",
            formFillNotes: "導入目的は業務効率化",
            writingStyle: "硬すぎない",
            preferredPhrases: "ありがとうございます",
            avoidedPhrases: "何卒"
        )

        profile.save(defaults: defaults)

        XCTAssertEqual(UserProfile.load(defaults: defaults), profile)
    }
}
