import CoreGraphics
import Foundation

/// Pure detector for a modifier-only chord such as fn + ⌘, ⌘ + ⇧, or a single ⌃.
/// The manager listens to `flagsChanged` and never swallows those events.
///
/// The chord only counts when it is reached on its own: building it up through
/// its own modifiers is fine, but another modifier, an ordinary key, or (for
/// `.tap`) a click since all modifiers were last up means the user is typing
/// some other shortcut such as ⌘⇧T.
public struct ModifierChordDetector: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// Fires once (`.tapped`) when the chord is let go within
        /// `maxTapDuration` with nothing else pressed or clicked meanwhile.
        case tap
        /// Push-to-talk: `.pressed` when the chord is complete, `.released` when
        /// it is let go, `.cancelled` instead when an ordinary key (or another
        /// modifier) arrives while it is held.
        case hold
    }

    public enum Action: Equatable, Sendable {
        case pressed
        case released
        case cancelled
        case tapped
        case none
    }

    public var requiredFlags: CGEventFlags
    public var style: Style
    public var debounceInterval: TimeInterval
    public var maxTapDuration: TimeInterval

    private var currentFlags: CGEventFlags = []
    private var isHeld = false
    private var heldSince: TimeInterval = 0
    private var lastPressAt: TimeInterval?
    /// `.tap` only: something else happened while the chord was held.
    private var isInterrupted = false
    /// Something else happened since all modifiers were last up.
    private var isBlocked = false
    private var extraKeyDownCount = 0

    /// Caps Lock is a lock state, not a held key, so it is ignored.
    private static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]

    public init(
        requiredFlags: CGEventFlags,
        style: Style = .tap,
        debounceInterval: TimeInterval = 0.150,
        maxTapDuration: TimeInterval = 0.6
    ) {
        self.requiredFlags = requiredFlags
        self.style = style
        self.debounceInterval = debounceInterval
        self.maxTapDuration = maxTapDuration
    }

    public mutating func handle(flags: CGEventFlags, at time: TimeInterval) -> Action {
        let current = flags.intersection(Self.relevantFlags)
        let required = requiredFlags.intersection(Self.relevantFlags)
        currentFlags = current

        if current.isEmpty {
            let action = isHeld ? letGo(at: time) : .none
            isBlocked = false
            return action
        }

        if isHeld {
            if current == required {
                return .none
            }
            if current.isSuperset(of: required) {
                // Another modifier joined: ⌘⇧ held, then ⌥ for ⌘⇧⌥something.
                return interrupt(cancelsHold: true)
            }
            // One of the chord's modifiers was let go.
            return letGo(at: time)
        }

        guard required.isSuperset(of: current) else {
            isBlocked = true
            return .none
        }
        guard current == required, !isBlocked, extraKeyDownCount == 0 else {
            return .none
        }
        if style == .hold, let lastPressAt, time - lastPressAt < debounceInterval {
            return .none
        }
        isHeld = true
        isInterrupted = false
        heldSince = time
        lastPressAt = time
        return style == .hold ? .pressed : .none
    }

    /// An ordinary key went down (this tap saw it).
    public mutating func handleNonModifierKeyDown() -> Action {
        extraKeyDownCount += 1
        return interrupt(cancelsHold: true)
    }

    public mutating func handleNonModifierKeyUp() {
        extraKeyDownCount = max(0, extraKeyDownCount - 1)
    }

    /// An ordinary key went down but another shortcut's tap swallowed it, so
    /// this tap never saw the key itself (nor will it see the key-up).
    public mutating func handleKeySwallowedElsewhere() -> Action {
        interrupt(cancelsHold: true)
    }

    /// A mouse button went down. Prevents a `.tap` (⌘-click is not a ⌘ tap);
    /// a held push-to-talk chord keeps listening.
    public mutating func handleMouseDown() -> Action {
        interrupt(cancelsHold: false)
    }

    /// Drops all physical state after an event tap is disabled, replaced, or
    /// resumes after sleep/secure input. Returns whether the chord was held so
    /// the owner can deliver one synthetic release to a push-to-talk consumer.
    @discardableResult
    public mutating func reset() -> Bool {
        let wasHeld = isHeld
        currentFlags = []
        isHeld = false
        isInterrupted = false
        isBlocked = false
        lastPressAt = nil
        extraKeyDownCount = 0
        return wasHeld
    }

    private mutating func letGo(at time: TimeInterval) -> Action {
        isHeld = false
        // Re-pressing a released modifier must not fire again until everything is up.
        isBlocked = true
        switch style {
        case .hold:
            return .released
        case .tap:
            return !isInterrupted && time - heldSince <= maxTapDuration ? .tapped : .none
        }
    }

    private mutating func interrupt(cancelsHold: Bool) -> Action {
        guard isHeld else {
            if !currentFlags.isEmpty {
                isBlocked = true
            }
            return .none
        }
        switch style {
        case .tap:
            isInterrupted = true
            return .none
        case .hold:
            guard cancelsHold else {
                return .none
            }
            isHeld = false
            isBlocked = true
            return .cancelled
        }
    }
}

public extension VoiceActivationMode {
    /// Toggle mode starts/confirms on a clean tap; hold mode listens while held.
    var modifierChordStyle: ModifierChordDetector.Style {
        switch self {
        case .toggleOnly: .tap
        case .holdOrTap: .hold
        }
    }
}
