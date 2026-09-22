import Foundation

public struct RewritePromptBuilder {
    public init() {}

    public func systemInstruction() -> String {
        """
        あなたは返信文作成アシスタントです。
        ユーザーが今入力している下書きと、入力欄の上に表示されている会話文脈をもとに、送信前の返信文を1つだけ作成してください。
        会話文脈を必ず先に読み、直前の相手の質問・依頼・提案に対する返信として下書きを解釈してください。
        下書きが「いいよ」「OK」「了解」「はい」「お願いします」など短い場合は、文脈に合わせて承諾・確認・依頼の内容を自然に具体化してください。
        ユーザープロフィールは文体・立場・好みを合わせるためだけに使い、相手に不要な個人情報を勝手に書かないでください。
        返信文以外の説明、引用符、箇条書き、前置きは出力しないでください。
        下書きの意図を変えず、文脈にない事実は勝手に補完しないでください。
        """
    }

    public func userPrompt(for request: RewriteRequest) -> String {
        let bundleID = request.appInfo.bundleIdentifier ?? "unknown"
        let context = formattedContext(request.context)
        let draft = request.draft.isEmpty ? "(下書きなし)" : request.draft
        let profile = request.userProfile.promptText()

        return """
        アプリ: \(request.appInfo.name)
        Bundle ID: \(bundleID)
        文体モード: \(request.mode.instruction)
        出力言語: \(request.language.instruction)

        ユーザープロフィール:
        \(profile)

        入力欄の上に見えている文脈:
        ※上から画面の上→下の順です。最後の数行ほど、入力欄と返信先に近い可能性が高いです。
        \(context)

        ユーザーの下書き:
        \(draft)

        条件:
        - \(request.language.instruction)
        - 送信文だけを返す
        - 1つの返信として自然にする
        - ユーザーの文体・立場・避けたい言い回しを反映する
        - プロフィール内の個人情報は、会話上必要な場合だけ自然に使う
        - 文脈内の直前の質問・依頼・提案への返答になるようにする
        - 下書きが短い承諾なら、何を承諾しているかが相手に伝わる文にする
        - 文脈から確実に分かる日時・対象・条件は返信に反映する
        - 文脈がノイズっぽい場合は、入力欄に最も近そうな後半の行を優先する
        - SlackやMessengerなら硬すぎない文にする
        - 顧客や上司っぽい文脈なら失礼のない文にする
        - 絵文字は下書きか文脈に自然に含まれる場合だけ使う
        """
    }

    private func formattedContext(_ rawContext: String) -> String {
        let lines = rawContext
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return "(文脈なし)"
        }

        return lines.enumerated()
            .map { index, line in "\(index + 1). \(line)" }
            .joined(separator: "\n")
    }
}
