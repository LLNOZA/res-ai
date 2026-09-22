import Foundation

/// Truncates a reading-order list so both the opening and the latest lines survive.
public enum ContextWindow {
    /// When `items` is longer than `limit`, keep an opening slice plus the closing slice.
    /// Order is unchanged. If it already fits, the list is returned as-is.
    public static func headAndTail<T>(_ items: [T], limit: Int, headRatio: Double = 1.0 / 3.0) -> [T] {
        guard limit > 0 else {
            return []
        }
        guard items.count > limit else {
            return items
        }

        let headCount = min(max(1, Int((Double(limit) * headRatio).rounded(.down))), limit - 1)
        let tailCount = limit - headCount
        return Array(items.prefix(headCount)) + Array(items.suffix(tailCount))
    }
}
