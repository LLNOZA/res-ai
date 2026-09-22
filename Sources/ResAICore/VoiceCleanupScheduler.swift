import Foundation

/// Pure policy for overlapping Gemini cleanups: a newer session must not cancel
/// the previous one, keyboard swap is forbidden once a newer session/insertion
/// exists, and `lastCleanup` is only updated for the latest insertion.
public enum VoiceCleanupScheduler {
    public static let maxPendingCount = 3

    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case finishing
    }

    public struct Decision: Equatable, Sendable {
        public var allowKeyboardSwap: Bool
        public var updateLastCleanup: Bool
        public var isBackground: Bool

        public init(allowKeyboardSwap: Bool, updateLastCleanup: Bool, isBackground: Bool) {
            self.allowKeyboardSwap = allowKeyboardSwap
            self.updateLastCleanup = updateLastCleanup
            self.isBackground = isBackground
        }
    }

    public static func decide(
        cleanupInsertionID: UUID,
        latestInsertionID: UUID?,
        phase: Phase
    ) -> Decision {
        let belongsToLatestInsertion = latestInsertionID == cleanupInsertionID
        let newerSessionActive = phase == .listening || phase == .finishing
        return Decision(
            allowKeyboardSwap: belongsToLatestInsertion && !newerSessionActive,
            updateLastCleanup: belongsToLatestInsertion,
            isBackground: !belongsToLatestInsertion || newerSessionActive
        )
    }

    /// Oldest pending IDs that must be cancelled so that adding `newID` stays within the cap.
    public static func overflowIDs(pendingOrder: [UUID], adding newID: UUID) -> [UUID] {
        let order = pendingOrder.filter { $0 != newID }
        let overflowCount = order.count + 1 - maxPendingCount
        guard overflowCount > 0 else {
            return []
        }
        return Array(order.prefix(overflowCount))
    }
}
