import Foundation

public enum DictationJoiner {
    /// Returns the text to insert, possibly prefixed with a single space.
    public static func prepare(_ text: String, precededBy before: String?, localeIdentifier: String) -> String {
        guard let before, !before.isEmpty else {
            return text
        }

        if let last = before.last, last.isWhitespace || last.isNewline {
            return text
        }

        if isCJKLanguage(localeIdentifier) {
            return text
        }

        return " " + text
    }

    private static func isCJKLanguage(_ localeIdentifier: String) -> Bool {
        let locale = Locale(identifier: localeIdentifier)
        let code = locale.language.languageCode?.identifier.lowercased()
            ?? localeIdentifier.split { $0 == "_" || $0 == "-" }.first.map { String($0).lowercased() }
            ?? ""
        let base = String(code.prefix(2))
        return base == "ja" || base == "zh" || base == "ko"
    }
}
