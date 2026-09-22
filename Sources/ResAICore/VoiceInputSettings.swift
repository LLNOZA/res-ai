import Foundation

public enum VoiceActivationMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case toggleOnly
    case holdOrTap

    public var id: String { rawValue }

    public var ignoresKeyUp: Bool {
        self == .toggleOnly
    }

    public var displayName: String {
        switch self {
        case .toggleOnly:
            "押して開始 / 押して確定"
        case .holdOrTap:
            "長押し"
        }
    }

    public var readinessLabel: String {
        switch self {
        case .holdOrTap:
            "長押し/タップ"
        case .toggleOnly:
            "トグル"
        }
    }
}

/// How far Gemini may go when it rewrites the inserted transcript.
public enum DictationCleanupStyle: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// Filler / stutter / homophone fixes only. Wording stays the speaker's.
    case light
    /// Understand what the speaker meant and write it as a clean sentence.
    case rewrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: "軽く整える"
        case .rewrite: "意味を汲んで文章化"
        }
    }

    public var help: String {
        switch self {
        case .light:
            "フィラー・言い直し・重複・同音語の誤りだけ直します。言葉遣いは話したままです。"
        case .rewrite:
            "話し言葉を、言いたかった意味が伝わる読みやすい文章に書き直します。情報は足しません。"
        }
    }
}

public struct VoiceInputSettings: Equatable, Sendable {
    public var cleanupEnabled: Bool
    public var cleanupStyle: DictationCleanupStyle
    public var geminiModel: String
    public var localeIdentifier: String
    public var cleanupTimeoutSeconds: Double
    public var includeScreenContext: Bool
    public var activationMode: VoiceActivationMode

    public init(
        cleanupEnabled: Bool = true,
        cleanupStyle: DictationCleanupStyle = .rewrite,
        geminiModel: String = "gemini-3.8-flash",
        localeIdentifier: String = "ja_JP",
        cleanupTimeoutSeconds: Double = 6.0,
        includeScreenContext: Bool = true,
        activationMode: VoiceActivationMode = .toggleOnly
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.cleanupStyle = cleanupStyle
        self.geminiModel = geminiModel
        self.localeIdentifier = localeIdentifier
        self.cleanupTimeoutSeconds = cleanupTimeoutSeconds
        self.includeScreenContext = includeScreenContext
        self.activationMode = activationMode
    }

    public static func load(defaults: UserDefaults = .standard) -> VoiceInputSettings {
        let cleanupEnabled = defaults.object(forKey: DefaultsKey.cleanupEnabled) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.cleanupEnabled)
        let includeScreenContext = defaults.object(forKey: DefaultsKey.includeScreenContext) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.includeScreenContext)

        let storedModel = defaults.string(forKey: DefaultsKey.geminiModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiModel: String
        if let storedModel, !storedModel.isEmpty {
            geminiModel = storedModel
        } else {
            geminiModel = "gemini-3.8-flash"
        }

        let storedLocale = defaults.string(forKey: DefaultsKey.locale)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localeIdentifier: String
        if let storedLocale, !storedLocale.isEmpty {
            localeIdentifier = storedLocale
        } else {
            localeIdentifier = "ja_JP"
        }

        let cleanupTimeoutSeconds: Double
        if defaults.object(forKey: DefaultsKey.cleanupTimeout) == nil {
            cleanupTimeoutSeconds = 6.0
        } else {
            cleanupTimeoutSeconds = defaults.double(forKey: DefaultsKey.cleanupTimeout)
        }

        let cleanupStyle: DictationCleanupStyle
        if let raw = defaults.string(forKey: DefaultsKey.cleanupStyle),
           let stored = DictationCleanupStyle(rawValue: raw) {
            cleanupStyle = stored
        } else {
            cleanupStyle = .rewrite
        }

        let activationMode: VoiceActivationMode
        if let raw = defaults.string(forKey: DefaultsKey.activationMode),
           let stored = VoiceActivationMode(rawValue: raw) {
            activationMode = stored
        } else {
            activationMode = .toggleOnly
        }

        return VoiceInputSettings(
            cleanupEnabled: cleanupEnabled,
            cleanupStyle: cleanupStyle,
            geminiModel: geminiModel,
            localeIdentifier: localeIdentifier,
            cleanupTimeoutSeconds: cleanupTimeoutSeconds,
            includeScreenContext: includeScreenContext,
            activationMode: activationMode
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(cleanupEnabled, forKey: DefaultsKey.cleanupEnabled)
        defaults.set(cleanupStyle.rawValue, forKey: DefaultsKey.cleanupStyle)
        defaults.set(geminiModel, forKey: DefaultsKey.geminiModel)
        defaults.set(localeIdentifier, forKey: DefaultsKey.locale)
        defaults.set(cleanupTimeoutSeconds, forKey: DefaultsKey.cleanupTimeout)
        defaults.set(includeScreenContext, forKey: DefaultsKey.includeScreenContext)
        defaults.set(activationMode.rawValue, forKey: DefaultsKey.activationMode)
    }

    public enum DefaultsKey {
        public static let cleanupEnabled = "dictation.cleanupEnabled"
        public static let cleanupStyle = "dictation.cleanupStyle"
        public static let geminiModel = "dictation.geminiModel"
        public static let locale = "dictation.locale"
        public static let cleanupTimeout = "dictation.cleanupTimeout"
        public static let includeScreenContext = "dictation.includeScreenContext"
        public static let activationMode = "dictation.activationMode"
    }
}

public enum GeminiAPIKeyStore {
    private static let account = "gemini.apiKey"

    public static func load() -> String? {
        let value = (try? KeychainStore().string(for: account))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    public static func save(_ key: String) throws {
        try KeychainStore().setString(key, for: account)
    }
}
