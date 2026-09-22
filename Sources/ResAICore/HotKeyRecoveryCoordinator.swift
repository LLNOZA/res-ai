import Foundation

/// A snapshot supplied by the app-level watchdog. It contains only observable
/// state, so recovery decisions can be tested without creating Core Graphics taps.
public struct HotKeySlotHealth: Equatable, Sendable {
    public let name: String
    public let isRegistered: Bool
    public let isEnabled: Bool
    public let secondsSinceEvent: TimeInterval?

    public init(
        name: String,
        isRegistered: Bool,
        isEnabled: Bool,
        secondsSinceEvent: TimeInterval?
    ) {
        self.name = name
        self.isRegistered = isRegistered
        self.isEnabled = isEnabled
        self.secondsSinceEvent = secondsSinceEvent
    }
}

public enum HotKeyRecoveryAction: Equatable, Sendable {
    case registerMissing
    case repairDisabled(slot: String)
    case recreateStale(slot: String)
}

/// Selects the smallest lifecycle repair justified by current evidence.
///
/// In particular, there is no elapsed-time-only branch: a healthy, idle tap is
/// left alone. A stale enabled tap is recreated only when an independent global
/// monitor observed a real user key recently and this tap did not observe it.
public struct HotKeyRecoveryCoordinator: Sendable {
    public var staleAfter: TimeInterval
    public var externalEventWindow: TimeInterval

    public init(staleAfter: TimeInterval = 2.0, externalEventWindow: TimeInterval = 2.0) {
        self.staleAfter = staleAfter
        self.externalEventWindow = externalEventWindow
    }

    public func actions(
        slots: [HotKeySlotHealth],
        secureInputActive: Bool,
        permissionAvailable: Bool,
        secondsSinceExternalEvent: TimeInterval?
    ) -> [HotKeyRecoveryAction] {
        guard permissionAvailable, !secureInputActive else {
            return []
        }

        let hasRecentExternalEvent = secondsSinceExternalEvent.map {
            $0 >= 0 && $0 <= externalEventWindow
        } ?? false

        var actions: [HotKeyRecoveryAction] = []
        if slots.contains(where: { !$0.isRegistered }) {
            actions.append(.registerMissing)
        }

        for slot in slots where slot.isRegistered {
            if !slot.isEnabled {
                actions.append(.repairDisabled(slot: slot.name))
            } else if hasRecentExternalEvent,
                      let secondsSinceEvent = slot.secondsSinceEvent,
                      secondsSinceEvent >= staleAfter
            {
                actions.append(.recreateStale(slot: slot.name))
            }
        }
        return actions
    }
}
