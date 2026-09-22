import Foundation

public enum GeneratedReplySanitizer {
    public static func sanitize(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = stripMarkdownFence(from: text)
        text = stripCommonPrefix(from: text)
        text = stripSingleLeadingListMarker(from: text)
        text = stripWrappingQuotes(from: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMarkdownFence(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else {
            return text
        }

        let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard first.hasPrefix("```"), last == "```" else {
            return text
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func stripCommonPrefix(from text: String) -> String {
        let prefixes = [
            "返信文:",
            "返信文：",
            "返信:",
            "返信：",
            "送信文:",
            "送信文：",
            "出力:",
            "出力：",
            "回答:",
            "回答：",
            "Reply:",
            "Response:"
        ]

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                return String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private static func stripSingleLeadingListMarker(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 1 else {
            return text
        }

        let trimmed = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["- ", "* ", "・"]
        for marker in markers where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }

        if let dotIndex = trimmed.firstIndex(of: "."),
           trimmed[..<dotIndex].allSatisfy(\.isNumber) {
            return String(trimmed[trimmed.index(after: dotIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    private static func stripWrappingQuotes(from text: String) -> String {
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("「", "」"),
            ("『", "』")
        ]

        guard let first = text.first, let last = text.last, text.count >= 2 else {
            return text
        }

        for pair in quotePairs where first == pair.0 && last == pair.1 {
            return String(text.dropFirst().dropLast())
        }

        return text
    }
}
