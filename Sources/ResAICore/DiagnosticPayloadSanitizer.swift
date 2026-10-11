import Foundation

/// Reduces a MetricKit diagnostic payload (`MXDiagnosticPayload.jsonRepresentation()`)
/// to its crash and hang reports. Call stacks, exception types/codes, signals, and the
/// OS/app versions stay; free-text fields that could carry runtime strings
/// (Objective-C exception messages and their arguments) are removed.
public enum DiagnosticPayloadSanitizer {
    static let keptTopLevelKeys: Set<String> = [
        "timeStampBegin", "timeStampEnd", "crashDiagnostics", "hangDiagnostics"
    ]
    static let reportKeys = ["crashDiagnostics", "hangDiagnostics"]
    static let removedKeys: Set<String> = ["composedMessage", "arguments"]

    /// Returns nil when the payload is unreadable or has no crash or hang report.
    public static func sanitize(_ data: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var kept: [String: Any] = [:]
        for (key, value) in object where keptTopLevelKeys.contains(key) {
            kept[key] = strip(value)
        }
        let hasReports = reportKeys.contains { key in
            (kept[key] as? [Any]).map { !$0.isEmpty } ?? false
        }
        guard hasReports else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys])
    }

    private static func strip(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in dictionary where !removedKeys.contains(key) {
                result[key] = strip(nested)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(strip)
        }
        return value
    }
}
