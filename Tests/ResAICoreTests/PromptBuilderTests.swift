import XCTest
@testable import ResAICore

final class PromptBuilderTests: XCTestCase {
    func testUserPromptContainsDraftContextAndMode() {
        let builder = RewritePromptBuilder()
        let request = RewriteRequest(
            appInfo: AppInfo(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 123),
            draft: "明日でいいよ",
            context: "明日でも大丈夫ですか？",
            mode: .polite,
            userProfile: UserProfile(
                displayName: "Example User",
                role: "AIプロダクトの事業責任者",
                background: "BtoBの相手とやり取りすることが多い",
                writingStyle: "短めで、硬すぎず、感じよく",
                preferredPhrases: "ありがとうございます、助かります",
                avoidedPhrases: "承知いたしました"
            )
        )

        let prompt = builder.userPrompt(for: request)

        XCTAssertTrue(prompt.contains("Slack"))
        XCTAssertTrue(prompt.contains("Example User"))
        XCTAssertTrue(prompt.contains("短めで、硬すぎず、感じよく"))
        XCTAssertTrue(prompt.contains("承知いたしました"))
        XCTAssertTrue(prompt.contains("1. 明日でも大丈夫ですか？"))
        XCTAssertTrue(prompt.contains("明日でいいよ"))
        XCTAssertTrue(prompt.contains(RewriteMode.polite.instruction))
        XCTAssertTrue(prompt.contains(RewriteLanguage.japanese.instruction))
        XCTAssertTrue(prompt.contains("直前の質問・依頼・提案への返答"))
        XCTAssertTrue(prompt.contains("短い承諾"))
        XCTAssertTrue(prompt.contains("個人情報は、会話上必要な場合だけ"))
    }

    func testUserPromptMarksMissingContext() {
        let builder = RewritePromptBuilder()
        let request = RewriteRequest(
            appInfo: AppInfo(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", processIdentifier: 123),
            draft: "いいよ",
            context: "",
            mode: .balanced
        )

        let prompt = builder.userPrompt(for: request)

        XCTAssertTrue(prompt.contains("(文脈なし)"))
        XCTAssertTrue(prompt.contains("いいよ"))
    }

    func testUserPromptCanRequestEnglishOutput() {
        let builder = RewritePromptBuilder()
        let request = RewriteRequest(
            appInfo: AppInfo(name: "Messenger", bundleIdentifier: "com.apple.Safari", processIdentifier: 123),
            draft: "いいよ",
            context: "Can we move the meeting to tomorrow?",
            mode: .balanced,
            language: .english
        )

        let prompt = builder.userPrompt(for: request)

        XCTAssertTrue(prompt.contains("Reply in natural English"))
        XCTAssertFalse(prompt.contains("- 日本語で返す"))
    }
}
