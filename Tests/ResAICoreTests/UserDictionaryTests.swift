import XCTest
@testable import ResAICore

final class UserDictionaryTests: XCTestCase {
    func testApplyReplacesLongestRecognizedFirst() {
        let dictionary = UserDictionary(entries: [
            DictionaryEntry(recognized: "東京", preferred: "Tokyo"),
            DictionaryEntry(recognized: "東京タワー", preferred: "Tokyo Tower")
        ])

        XCTAssertEqual(dictionary.apply(to: "東京タワーに行く"), "Tokyo Towerに行く")
        XCTAssertEqual(dictionary.apply(to: "東京に行く"), "Tokyoに行く")
    }

    func testApplyReplacesAllOccurrencesAndSkipsEmptyFields() {
        let dictionary = UserDictionary(entries: [
            DictionaryEntry(recognized: "foo", preferred: "bar"),
            DictionaryEntry(recognized: "", preferred: "x"),
            DictionaryEntry(recognized: "y", preferred: "")
        ])

        XCTAssertEqual(dictionary.apply(to: "foo foo y"), "bar bar y")
    }

    func testApplyDoesNotUseVocabularyAsLiteralReplacement() {
        let dictionary = UserDictionary(entries: [
            DictionaryEntry(recognized: "", preferred: "Funnel Ai"),
            DictionaryEntry(recognized: "ふぁねるあい", preferred: "Funnel Ai")
        ])

        XCTAssertEqual(dictionary.apply(to: "あいう"), "あいう")
        XCTAssertEqual(dictionary.apply(to: "ふぁねるあいです"), "Funnel Aiです")
    }

    func testPromptTextSplitsReplacementAndVocabularyBlocks() {
        XCTAssertEqual(UserDictionary().promptText(), "")

        let mixed = UserDictionary(entries: [
            DictionaryEntry(recognized: "ふぁねるあい", preferred: "Funnel Ai"),
            DictionaryEntry(recognized: "", preferred: "Cursor"),
            DictionaryEntry(recognized: "", preferred: "商談化率"),
            DictionaryEntry(recognized: "y", preferred: "")
        ])
        XCTAssertEqual(
            mixed.promptText(),
            """
            置換ルール:
            ふぁねるあい → Funnel Ai
            よく使う語彙（同音・類似の誤認識はこの表記に寄せる）:
            Cursor, 商談化率
            """
        )

        let replacementsOnly = UserDictionary(entries: [
            DictionaryEntry(recognized: "レスエーアイ", preferred: "ResAI")
        ])
        XCTAssertEqual(
            replacementsOnly.promptText(),
            """
            置換ルール:
            レスエーアイ → ResAI
            """
        )

        let vocabularyOnly = UserDictionary(entries: [
            DictionaryEntry(recognized: "", preferred: "Cursor")
        ])
        XCTAssertEqual(
            vocabularyOnly.promptText(),
            """
            よく使う語彙（同音・類似の誤認識はこの表記に寄せる）:
            Cursor
            """
        )
    }

    func testAddVocabularySplitsTrimsAndDedupesCaseInsensitively() {
        var dictionary = UserDictionary(entries: [
            DictionaryEntry(recognized: "ふぁねるあい", preferred: "Funnel Ai")
        ])
        dictionary.addVocabulary("Funnel Ai, Cursor、 商談化率\n cursor \n,  ,\nResAI")

        XCTAssertEqual(dictionary.entries.map(\.preferred), ["Funnel Ai", "Cursor", "商談化率", "ResAI"])
        XCTAssertEqual(dictionary.entries.map(\.recognized), ["ふぁねるあい", "", "", ""])
    }

    func testIsValidRequiresNonEmptyPreferred() {
        XCTAssertTrue(UserDictionary.isValid(DictionaryEntry(recognized: "", preferred: "Cursor")))
        XCTAssertTrue(UserDictionary.isValid(DictionaryEntry(recognized: "a", preferred: "b")))
        XCTAssertFalse(UserDictionary.isValid(DictionaryEntry(recognized: "a", preferred: "")))
        XCTAssertFalse(UserDictionary.isValid(DictionaryEntry(recognized: "a", preferred: "  ")))
    }

    func testSaveAndLoadRoundTrip() {
        let suiteName = "UserDictionaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dictionary = UserDictionary(entries: [
            DictionaryEntry(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                recognized: "制度",
                preferred: "精度"
            )
        ])
        dictionary.save(defaults: defaults)

        XCTAssertEqual(UserDictionary.load(defaults: defaults), dictionary)
        XCTAssertEqual(UserDictionary.load(defaults: UserDefaults(suiteName: "UserDictionaryTests.empty.\(UUID().uuidString)")!), UserDictionary())
    }
}
