import ApplicationServices
import CoreGraphics
import Foundation

public struct AppInfo: Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var processIdentifier: pid_t?

    public init(name: String, bundleIdentifier: String?, processIdentifier: pid_t?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

public struct ContextLine: Equatable, Sendable {
    public var text: String
    public var frame: CGRect?

    public init(text: String, frame: CGRect? = nil) {
        self.text = text
        self.frame = frame
    }
}

public struct FocusedComposition {
    public var appInfo: AppInfo
    public var inputElement: AXUIElement
    public var inputFrame: CGRect?
    public var selectedTextRange: CFRange?
    /// The complete AXValue captured before selection-aware reading. `draftText` may contain
    /// only the selected text; this value is what guarded replacement compares immediately
    /// before mutation.
    public var originalFieldValue: String?
    public var draftText: String
    public var contextLines: [ContextLine]
    public var contextDiagnostics: ContextCaptureDiagnostics

    public init(
        appInfo: AppInfo,
        inputElement: AXUIElement,
        inputFrame: CGRect?,
        selectedTextRange: CFRange? = nil,
        originalFieldValue: String? = nil,
        draftText: String,
        contextLines: [ContextLine],
        contextDiagnostics: ContextCaptureDiagnostics = ContextCaptureDiagnostics()
    ) {
        self.appInfo = appInfo
        self.inputElement = inputElement
        self.inputFrame = inputFrame
        self.selectedTextRange = selectedTextRange
        self.originalFieldValue = originalFieldValue
        self.draftText = draftText
        self.contextLines = contextLines
        self.contextDiagnostics = contextDiagnostics
    }

    public var contextText: String {
        contextLines.map(\.text).joined(separator: "\n")
    }
}

/// The immutable edit intent captured before an AI result is applied.
///
/// Accessibility exposes ranges in UTF-16 offsets. Keeping this calculation as a pure value
/// operation makes it possible to prove that an edit replaces only the selected portion and that
/// the unselected prefix/suffix are preserved. Invalid ranges fail closed: the failable initializer
/// and `make` return nil instead of silently turning a selection edit into a full-field overwrite.
public struct CapturedTextEditPlan: Equatable, @unchecked Sendable {
    public let originalValue: String
    public let selectedRange: CFRange?
    public let replacementText: String
    public let expectedValue: String

    public static func == (lhs: CapturedTextEditPlan, rhs: CapturedTextEditPlan) -> Bool {
        lhs.originalValue == rhs.originalValue
            && lhs.replacementText == rhs.replacementText
            && lhs.expectedValue == rhs.expectedValue
            && ((lhs.selectedRange == nil && rhs.selectedRange == nil)
                || (lhs.selectedRange?.location == rhs.selectedRange?.location
                    && lhs.selectedRange?.length == rhs.selectedRange?.length))
    }

    public init?(originalValue: String, selectedRange: CFRange?, replacementText: String) {
        self.originalValue = originalValue
        self.selectedRange = selectedRange
        self.replacementText = replacementText
        guard let expectedValue = Self.valueByReplacingSelection(
            originalValue: originalValue,
            selectedRange: selectedRange,
            replacementText: replacementText
        ) else {
            return nil
        }
        self.expectedValue = expectedValue
    }

    public static func make(
        originalValue: String,
        selectedRange: CFRange?,
        replacementText: String
    ) -> CapturedTextEditPlan? {
        CapturedTextEditPlan(
            originalValue: originalValue,
            selectedRange: selectedRange,
            replacementText: replacementText
        )
    }

    /// Returns the full value after replacing `selectedRange`, or nil when the range is invalid
    /// or splits a UTF-16 surrogate pair.
    public static func valueByReplacingSelection(
        originalValue: String,
        selectedRange: CFRange?,
        replacementText: String
    ) -> String? {
        guard let selectedRange else {
            return replacementText
        }
        guard selectedRange.location >= 0, selectedRange.length >= 0 else {
            return nil
        }

        let utf16 = originalValue.utf16
        guard
            let startOffset = Int(exactly: selectedRange.location),
            let selectionLength = Int(exactly: selectedRange.length)
        else {
            return nil
        }
        let (endOffset, overflow) = startOffset.addingReportingOverflow(selectionLength)
        guard !overflow, startOffset <= endOffset, endOffset <= utf16.count else {
            return nil
        }

        let startUTF16 = utf16.index(utf16.startIndex, offsetBy: startOffset)
        let endUTF16 = utf16.index(utf16.startIndex, offsetBy: endOffset)
        guard
            let start = String.Index(startUTF16, within: originalValue),
            let end = String.Index(endUTF16, within: originalValue)
        else {
            return nil
        }

        return String(originalValue[..<start]) + replacementText + String(originalValue[end...])
    }
}

public struct FocusedInputTarget {
    public var appInfo: AppInfo
    public var inputElement: AXUIElement
    public var inputFrame: CGRect?
    public var selectedTextRange: CFRange?

    public init(
        appInfo: AppInfo,
        inputElement: AXUIElement,
        inputFrame: CGRect?,
        selectedTextRange: CFRange? = nil
    ) {
        self.appInfo = appInfo
        self.inputElement = inputElement
        self.inputFrame = inputFrame
        self.selectedTextRange = selectedTextRange
    }
}

public struct ContextCaptureDiagnostics: Equatable {
    public var accessibilityLineCount: Int
    public var screenTextLineCount: Int
    public var screenTextAttempted: Bool
    public var screenTextAuthorized: Bool

    public init(
        accessibilityLineCount: Int = 0,
        screenTextLineCount: Int = 0,
        screenTextAttempted: Bool = false,
        screenTextAuthorized: Bool = false
    ) {
        self.accessibilityLineCount = accessibilityLineCount
        self.screenTextLineCount = screenTextLineCount
        self.screenTextAttempted = screenTextAttempted
        self.screenTextAuthorized = screenTextAuthorized
    }

    public var usedAccessibility: Bool {
        accessibilityLineCount > 0
    }

    public var usedScreenText: Bool {
        screenTextLineCount > 0
    }

    public var captureLabel: String {
        switch (usedScreenText, usedAccessibility) {
        case (true, true):
            "OCR+AX"
        case (true, false):
            "OCR"
        case (false, true):
            "AX"
        case (false, false):
            "文脈なし"
        }
    }
}

public enum RewriteMode: String, CaseIterable, Identifiable {
    case balanced
    case concise
    case polite
    case warm
    case decline
    case scheduling

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .balanced:
            "自然"
        case .concise:
            "短め"
        case .polite:
            "丁寧"
        case .warm:
            "やわらかめ"
        case .decline:
            "断る"
        case .scheduling:
            "日程調整"
        }
    }

    public var instruction: String {
        switch self {
        case .balanced:
            "自然で、丁寧すぎず、仕事相手にも違和感のない返信にしてください。"
        case .concise:
            "短く、要点だけが伝わる返信にしてください。"
        case .polite:
            "ビジネス向けに丁寧な返信にしてください。ただし過剰にかしこまりすぎないでください。"
        case .warm:
            "やわらかく、感じのよい返信にしてください。"
        case .decline:
            "相手への配慮を残しながら、やわらかく断る返信にしてください。"
        case .scheduling:
            "日程調整として自然で、候補日や確認事項が読みやすい返信にしてください。"
        }
    }
}

public enum RewriteLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .japanese:
            "日本語"
        case .english:
            "英語"
        case .auto:
            "自動"
        }
    }

    public var instruction: String {
        switch self {
        case .japanese:
            "日本語で返してください。英語の文脈でも、自然な日本語の返信にしてください。"
        case .english:
            "Reply in natural English. If the draft or context is Japanese, preserve the intent and translate it into natural English. Do not mix Japanese unless it is a name, product, quoted text, or unavoidable term."
        case .auto:
            "文脈と下書きの主な言語に合わせて返してください。判断に迷う場合は日本語で返してください。"
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> RewriteLanguage {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.language),
            let language = RewriteLanguage(rawValue: rawValue)
        else {
            return .japanese
        }
        return language
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: DefaultsKey.language)
    }

    public enum DefaultsKey {
        public static let language = "rewrite.language"
    }
}

public struct RewriteRequest: Equatable {
    public var appInfo: AppInfo
    public var draft: String
    public var context: String
    public var mode: RewriteMode
    public var language: RewriteLanguage
    public var userProfile: UserProfile

    public init(
        appInfo: AppInfo,
        draft: String,
        context: String,
        mode: RewriteMode,
        language: RewriteLanguage = .japanese,
        userProfile: UserProfile = UserProfile()
    ) {
        self.appInfo = appInfo
        self.draft = draft
        self.context = context
        self.mode = mode
        self.language = language
        self.userProfile = userProfile
    }
}

public struct RewriteResult: Equatable {
    public var text: String
    public var source: RewriteSource

    public init(text: String, source: RewriteSource) {
        self.text = text
        self.source = source
    }
}

public enum RewriteSource: String, Equatable {
    case vertexAI
    case cloudRunProxy
    case localPreview
}
