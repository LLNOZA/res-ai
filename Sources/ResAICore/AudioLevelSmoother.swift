import Foundation

/// Maps microphone amplitude to a 0…1 UI level, with EMA smoothing and a 30 Hz publish gate.
public struct AudioLevelSmoother: Equatable, Sendable {
    public static let minDBFS: Float = -50
    public static let maxDBFS: Float = -10
    public static let smoothingAlpha: Float = 0.35
    public static let minPublishInterval: TimeInterval = 1.0 / 30.0

    public private(set) var level: Float = 0

    public init(level: Float = 0) {
        self.level = level
    }

    public static func dbFS(fromRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else {
            return -.infinity
        }
        return 20 * log10(rms)
    }

    /// Maps −50 dBFS…−10 dBFS onto 0…1, clamping outside that range.
    public static func mapDBFS(_ db: Float) -> Float {
        guard db.isFinite else {
            return 0
        }
        if db <= minDBFS { return 0 }
        if db >= maxDBFS { return 1 }
        return (db - minDBFS) / (maxDBFS - minDBFS)
    }

    /// First sample always publishes; later samples must be at least `minPublishInterval` apart.
    public static func shouldPublish(lastSent: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastSent else {
            return true
        }
        return now - lastSent >= minPublishInterval
    }

    /// Exponential moving average with α = 0.35. `sample` is expected in 0…1.
    public mutating func push(_ sample: Float) -> Float {
        let clamped = min(max(sample, 0), 1)
        level = Self.smoothingAlpha * clamped + (1 - Self.smoothingAlpha) * level
        return level
    }
}
