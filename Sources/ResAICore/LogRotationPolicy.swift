import Foundation

public enum LogRotationPolicy: Sendable {
    public static let defaultLimit: UInt64 = 5 * 1024 * 1024

    public static func shouldRotate(size: UInt64, limit: UInt64 = defaultLimit) -> Bool {
        size > limit
    }

    /// When `current` exceeds `limit`, it is renamed to `rotated` (replacing any older rotated file).
    public static func rotateIfNeeded(
        current: URL,
        rotated: URL,
        limit: UInt64 = defaultLimit,
        fileManager: FileManager = .default
    ) {
        guard fileManager.fileExists(atPath: current.path) else {
            return
        }

        let size = (try? fileManager.attributesOfItem(atPath: current.path)[.size] as? UInt64) ?? 0
        guard shouldRotate(size: size, limit: limit) else {
            return
        }

        if fileManager.fileExists(atPath: rotated.path) {
            try? fileManager.removeItem(at: rotated)
        }
        try? fileManager.moveItem(at: current, to: rotated)
    }
}
