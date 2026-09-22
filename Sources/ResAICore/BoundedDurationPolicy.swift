import Foundation

/// Drop-oldest cap for a sequence of sample durations (queued speech buffers).
public enum BoundedDurationPolicy: Sendable {
    /// Newest items are kept so the sum is ≤ `maxDuration`. The newest item is always retained.
    public static func dropOldest(durations: [TimeInterval], maxDuration: TimeInterval) -> [TimeInterval] {
        var result = durations
        var total = result.reduce(0, +)
        while total > maxDuration, result.count > 1 {
            total -= result.removeFirst()
        }
        return result
    }
}
