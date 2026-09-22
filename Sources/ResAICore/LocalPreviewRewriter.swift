import Foundation

public struct LocalPreviewRewriter: TextRewriting {
    public init() {}

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        let draft = request.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String

        if draft.isEmpty {
            text = emptyPreviewText(language: request.language)
        } else {
            text = previewText(
                from: draft,
                mode: request.mode,
                language: request.language,
                profile: request.userProfile
            )
        }

        return RewriteResult(text: text, source: .localPreview)
    }

    private func emptyPreviewText(language: RewriteLanguage) -> String {
        switch language {
        case .english:
            "Thanks. I'll take a look and get back to you."
        case .japanese, .auto:
            "ありがとうございます。確認して、あらためてご連絡します。"
        }
    }

    private func previewText(
        from draft: String,
        mode: RewriteMode,
        language: RewriteLanguage,
        profile: UserProfile
    ) -> String {
        if language == .english {
            return englishPreviewText(from: draft, mode: mode)
        }

        let avoidsExcessivePoliteness = profile.avoidedPhrases.contains("承知")
            || profile.writingStyle.contains("硬すぎ")
            || profile.writingStyle.lowercased().contains("casual")

        switch mode {
        case .balanced:
            return avoidsExcessivePoliteness ? "ありがとうございます、\(draft)" : "ありがとうございます。\(draft)"
        case .concise:
            return draft
        case .polite:
            return avoidsExcessivePoliteness
                ? "ありがとうございます。\(draft) よろしくお願いします。"
                : "ありがとうございます。\(draft) よろしくお願いいたします。"
        case .warm:
            return "ありがとうございます！\(draft)"
        case .decline:
            return "ご連絡ありがとうございます。恐れ入りますが、今回は難しそうです。"
        case .scheduling:
            return "ありがとうございます。日程について確認しました。\(draft)"
        }
    }

    private func englishPreviewText(from draft: String, mode: RewriteMode) -> String {
        switch mode {
        case .balanced:
            "Thanks. \(draft)"
        case .concise:
            draft
        case .polite:
            "Thank you. \(draft) Best regards."
        case .warm:
            "Thanks! \(draft)"
        case .decline:
            "Thank you for reaching out. Unfortunately, I don't think this will work for us this time."
        case .scheduling:
            "Thanks. I checked the schedule. \(draft)"
        }
    }
}
