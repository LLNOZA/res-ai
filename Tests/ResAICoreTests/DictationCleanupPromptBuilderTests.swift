import XCTest
@testable import ResAICore

final class DictationCleanupPromptBuilderTests: XCTestCase {
    func testUserPromptContainsDictionaryRawTextAndAppName() {
        let builder = DictationCleanupPromptBuilder()
        let request = DictationCleanupRequest(
            rawText: "えー 制度を上げたい",
            appInfo: AppInfo(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 123),
            contextLines: ["認識精度の話です", "制度を確認してください"],
            dictionary: UserDictionary(entries: [
                DictionaryEntry(recognized: "レスエーアイ", preferred: "ResAI"),
                DictionaryEntry(recognized: "", preferred: "Cursor")
            ]),
            localeIdentifier: "ja_JP"
        )

        let prompt = builder.userPrompt(for: request)

        XCTAssertTrue(prompt.contains("Slack"))
        XCTAssertTrue(prompt.contains("置換ルール:"))
        XCTAssertTrue(prompt.contains("レスエーアイ → ResAI"))
        XCTAssertTrue(prompt.contains("よく使う語彙（同音・類似の誤認識はこの表記に寄せる）:"))
        XCTAssertTrue(prompt.contains("Cursor"))
        XCTAssertTrue(prompt.contains("えー 制度を上げたい"))
        XCTAssertTrue(prompt.contains("入力欄の上に見えている文脈（参考）"))
        XCTAssertTrue(prompt.contains("認識精度の話です"))
    }

    func testSystemInstructionMentionsDictionaryAndFillers() {
        let instruction = DictationCleanupPromptBuilder().systemInstruction()

        XCTAssertTrue(instruction.contains("辞書"))
        XCTAssertTrue(instruction.contains("フィラー"))
        XCTAssertTrue(instruction.contains("ユーザー辞書の表記は指定どおりに使う"))
        XCTAssertTrue(instruction.contains("語彙リストにある語は、音が近い誤認識をその表記に直す"))
    }

    func testSystemInstructionSwitchesByStyle() {
        let builder = DictationCleanupPromptBuilder()
        let light = builder.systemInstruction(style: .light)
        let rewrite = builder.systemInstruction(style: .rewrite)

        XCTAssertTrue(light.contains("クリーンアップ担当"))
        XCTAssertTrue(light.contains("言い直し・重複をまとめる"))
        XCTAssertTrue(rewrite.contains("文章化担当"))
        XCTAssertTrue(rewrite.contains("話者が言っていない情報・意見・理由を足す"))
        XCTAssertTrue(rewrite.contains("要約する、意味を丸める"))
        XCTAssertNotEqual(light, rewrite)
        XCTAssertEqual(builder.systemInstruction(), light)
    }
}
