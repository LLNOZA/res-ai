import XCTest
@testable import ResAICore

@MainActor
final class LocalPreviewRewriterTests: XCTestCase {
    func testProfileAvoidedPhraseSoftensPolitePreview() async throws {
        let rewriter = LocalPreviewRewriter()
        let request = RewriteRequest(
            appInfo: AppInfo(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 1),
            draft: "明日で大丈夫です",
            context: "明日でも大丈夫ですか？",
            mode: .polite,
            userProfile: UserProfile(
                writingStyle: "硬すぎない",
                avoidedPhrases: "承知いたしました"
            )
        )

        let result = try await rewriter.rewrite(request)

        XCTAssertTrue(result.text.contains("よろしくお願いします。"))
        XCTAssertFalse(result.text.contains("よろしくお願いいたします。"))
    }

    func testEnglishLanguageUsesEnglishPreview() async throws {
        let rewriter = LocalPreviewRewriter()
        let request = RewriteRequest(
            appInfo: AppInfo(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 1),
            draft: "tomorrow works for me",
            context: "Does tomorrow work?",
            mode: .polite,
            language: .english
        )

        let result = try await rewriter.rewrite(request)

        XCTAssertTrue(result.text.contains("Thank you."))
        XCTAssertTrue(result.text.contains("Best regards."))
    }
}
