import CoreGraphics
import Foundation

/// Pure press/release detector for a modifier-only chord such as fn + ⌘.
/// The manager listens to `flagsChanged` and never swallows those events.
public struct ModifierChordDetector: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pressed
        case released
        case none
    }

    public var requiredFlags: CGEventFlags
    public var debounceInterval: TimeInterval
    public var extraKeyCancelWindow: TimeInterval

    private var isHeld = false
    private var lastPressAt: TimeInterval?
    private var extraKeyDownCount = 0

    private static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
        .maskAlphaShift
    ]

    public init(
        requiredFlags: CGEventFlags,
        debounceInterval: TimeInterval = 0.150,
        extraKeyCancelWindow: TimeInterval = 0.300
    ) {
        self.requiredFlags = requiredFlags
        self.debounceInterval = debounceInterval
        self.extraKeyCancelWindow = extraKeyCancelWindow
    }

    public mutating func handle(flags: CGEventFlags, at time: TimeInterval) -> Action {
        let matches = matchesChord(flags) && extraKeyDownCount == 0

        if matches {
            if isHeld {
                return .none
            }
            if let lastPressAt, time - lastPressAt < debounceInterval {
                return .none
            }
            isHeld = true
            lastPressAt = time
            return .pressed
        }

        if isHeld {
            isHeld = false
            return .released
        }

        return .none
    }

    /// A non-modifier key while the chord is held is not our shortcut.
    /// If the press fired less than `extraKeyCancelWindow` ago, emit `.released`.
    public mutating func handleNonModifierKeyDown(at time: TimeInterval) -> Action {
        extraKeyDownCount += 1
        guard isHeld else {
            return .none
        }
        if let lastPressAt, time - lastPressAt < extraKeyCancelWindow {
            isHeld = false
            return .released
        }
        return .none
    }

    public mutating func handleNonModifierKeyUp() {
        extraKeyDownCount = max(0, extraKeyDownCount - 1)
    }

    /// Drops all physical state after an event tap is disabled, replaced, or
    /// resumes after sleep/secure input. Returns whether the chord was held so
    /// the owner can deliver one synthetic release to a push-to-talk consumer.
    @discardableResult
    public mutating func reset() -> Bool {
        let wasHeld = isHeld
        isHeld = false
        lastPressAt = nil
        extraKeyDownCount = 0
        return wasHeld
    }

    private func matchesChord(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Self.relevantFlags) == requiredFlags.intersection(Self.relevantFlags)
    }
}
