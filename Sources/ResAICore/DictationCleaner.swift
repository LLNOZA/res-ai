import Foundation

public struct DictationCleanupRequest: Equatable, @unchecked Sendable {
    public var rawText: String
    public var appInfo: AppInfo
    public var contextLines: [String]
    public var dictionary: UserDictionary
    public var localeIdentifier: String
    public var style: DictationCleanupStyle

    public init(
        rawText: String,
        appInfo: AppInfo,
        contextLines: [String] = [],
        dictionary: UserDictionary = UserDictionary(),
        localeIdentifier: String = "ja_JP",
        style: DictationCleanupStyle = .light
    ) {
        self.style = style
        self.rawText = rawText
        self.appInfo = appInfo
        self.contextLines = contextLines
        self.dictionary = dictionary
        self.localeIdentifier = localeIdentifier
    }
}

public protocol DictationCleaning: Sendable {
    func cleanup(_ request: DictationCleanupRequest, timeout: TimeInterval) async throws -> String
}

public struct DictationCleanupPromptBuilder: Sendable {
    public init() {}

    public func systemInstruction(style: DictationCleanupStyle = .light) -> String {
        switch style {
        case .light: lightSystemInstruction()
        case .rewrite: rewriteSystemInstruction()
        }
    }

    private func rewriteSystemInstruction() -> String {
        """
        あなたは音声入力の文章化担当です。入力欄にすでに挿入された音声認識の生テキスト（話し言葉そのまま）を受け取り、話者が言いたかった意味を読み取って、そのまま送信できる適切な文章に調整し、本文だけを出力してください。

        基本方針: 意味と言葉はできるだけ話者のまま残し、文として崩れているところだけを直す。要約や言い換えの作業ではない。話者が使った語や表現が文として成り立つなら、そのまま使う。

        すること:
        - まず「この人は何を伝えたいのか」を意味として理解し、その意味が正確に残る形で文を整える
        - フィラー（えー、あの、その、まあ、なんか）、言い直し、繰り返し、言いかけの断片は取り除く
          例: 「あの時にあのなんかせん選択肢から出てくるといいかもしれないよね」→「あの時に、選択肢から出てくるといいかもしれないよね。」
          例: 「文字。えっと文字情報として文字起こしが全部終わった後に。文字起こしが終わった後にこう重複して言ってしまってるやつとかをまとめたいですよね」→「文字情報として、文字起こしが全部終わった後に、重複して言ってしまっているものをまとめたいですよね。」
        - ねじれた語順や途中で切れた文は、意味が通る最小限の範囲で組み直す。通じている文はいじらない
        - 句読点、疑問文の「？」、必要なら改行を整える
        - 画面の文脈とアプリ名を手がかりに、同音異義語・漢字の誤りを直す
        - ユーザー辞書の表記は指定どおりに使う。語彙リストにある語は、音が近い誤認識をその表記に直す
        - 数字や英数字は自然な表記に整える

        してはいけないこと:
        - 話者が言っていない情報・意見・理由を足す
        - 要約する、意味を丸める、ニュアンス（「かも」「気がする」「なるべく」などの度合いや留保）を落とす
        - 内容を削る（フィラー・言い直し・重複以外は残す。短くなるのは重複が消えた結果だけ）
        - 話者の語を別の語に言い換える（意味が同じでも、必要がなければ置き換えない）
        - 丁寧さや口調のレベルを変える（タメ口はタメ口のまま、敬語は敬語のまま）
        - 挨拶や結びを足す
        - 翻訳する
        - 引用符で囲む、説明やラベルを付ける、複数案を出す

        入力がすでに整った文なら、そのまま返してください。
        """
    }

    private func lightSystemInstruction() -> String {
        """
        あなたは音声入力のクリーンアップ担当です。すでに入力欄へ挿入された音声認識の生テキストを受け取り、修正後の本文だけを出力してください。これは書き直しではなく、話し言葉の乱れ（フィラー・言い直し・重複）と誤認識を取り除き、話者が言いたかった文をそのまま文字にする作業です。

        すること:
        - フィラー（えー、あの、その、まあ、なんか など、つなぎ言葉として使われているもの）を取り除く
        - 言い直し・重複をまとめる。話し言葉では同じ語句や文を繰り返したり、途中で言い直したりする。最後に言い切った形を1回だけ残し、それ以前の途切れた断片や繰り返しは削る
          例: 「文字。えっと文字情報として」→「文字情報として」
          例: 「文字起こしが全部終わった後に。文字起こしが終わった後に」→「文字起こしが全部終わった後に」
          例: 「このこの瞬間」→「この瞬間」
          例: 「Aじゃなくて B」→ B
        - 句読点（、。）を整える。「意味わかりますか」のような疑問文には「？」を付けてよい
        - 画面の文脈とアプリ名を手がかりに、明らかな同音異義語・漢字の誤りを直す（例: 精度の話題なのに「制度」→「精度」）
        - ユーザー辞書の表記は指定どおりに使う。語彙リストにある語は、音が近い誤認識をその表記に直す
        - 数字や英数字は自然な表記に整える

        してはいけないこと:
        - 意味を変える
        - 話者が言っていない内容を足す。重複・言い直し・フィラー以外の内容を削る
        - 要約する
        - 丁寧さや口調を変える
        - 挨拶を足す
        - 翻訳する
        - 引用符で囲む
        - 説明やラベルを付ける

        直すところがなければ、入力をそのまま返してください。改行は保持してください。
        """
    }

    public func userPrompt(for request: DictationCleanupRequest) -> String {
        let bundleID = request.appInfo.bundleIdentifier ?? "unknown"
        let dictionary = request.dictionary.promptText()
        let dictionaryBlock = dictionary.isEmpty ? "(なし)" : dictionary
        let context = formattedContext(request.contextLines)
        let rawText = request.rawText.isEmpty ? "(空)" : request.rawText

        return """
        アプリ: \(request.appInfo.name)
        Bundle ID: \(bundleID)
        ロケール: \(request.localeIdentifier)

        ユーザー辞書:
        \(dictionaryBlock)

        入力欄の上に見えている文脈（参考）:
        \(context)

        -----音声認識テキスト-----
        \(rawText)
        -----ここまで-----
        """
    }

    private func formattedContext(_ lines: [String]) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let selected = ContextWindow.headAndTail(cleaned, limit: 8)
        guard !selected.isEmpty else {
            return "(文脈なし)"
        }
        return selected.enumerated()
            .map { index, line in "\(index + 1). \(line)" }
            .joined(separator: "\n")
    }
}

public final class GeminiDictationCleaner: DictationCleaning {
    private let client: GeminiAPIClient
    private let promptBuilder: DictationCleanupPromptBuilder

    public init(client: GeminiAPIClient, promptBuilder: DictationCleanupPromptBuilder = .init()) {
        self.client = client
        self.promptBuilder = promptBuilder
    }

    public func cleanup(_ request: DictationCleanupRequest, timeout: TimeInterval) async throws -> String {
        let rawText = request.rawText
        let textRequest = GeminiTextRequest(
            systemInstruction: promptBuilder.systemInstruction(style: request.style),
            userPrompt: promptBuilder.userPrompt(for: request),
            maxOutputTokens: maxOutputTokens(for: rawText),
            temperature: 0.1
        )
        let rawOutput = try await client.generateText(textRequest, timeout: timeout)
        let sanitized = GeneratedReplySanitizer.sanitize(rawOutput)
        try validate(sanitized, rawText: rawText, style: request.style)
        return sanitized
    }

    /// Output length is bounded by `validate`, not by this ceiling. Keep it generous so a
    /// thinking model that ignores `thinkingBudget: 0` cannot spend the whole budget on
    /// thoughts and return an empty answer (MAX_TOKENS).
    private func maxOutputTokens(for rawText: String) -> Int {
        min(4096, max(1024, rawText.utf16.count * 4 + 256))
    }

    private func validate(_ text: String, rawText: String, style: DictationCleanupStyle) throws {
        let rawCount = rawText.utf16.count
        let outCount = text.utf16.count
        if text.isEmpty {
            throw GeminiAPIError.rejectedOutput(reason: "empty after sanitize")
        }
        if outCount > Int(Double(rawCount) * 2.5) + 20 {
            throw GeminiAPIError.rejectedOutput(reason: "too long raw=\(rawCount) out=\(outCount)")
        }
        // 重複・言い直しが多い発話は半分以下に縮むことがあるため、下限はゆるめにしておく。
        // 文章化モードでも「要約しない」が方針なので、極端に縮んだ出力は丸めすぎとみなして捨てる。
        let floor = 0.2
        if rawCount > 0 && Double(outCount) < Double(rawCount) * floor {
            throw GeminiAPIError.rejectedOutput(reason: "too short raw=\(rawCount) out=\(outCount)")
        }
    }
}
