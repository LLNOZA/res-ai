import Carbon
import CoreGraphics

/// Converts Carbon shortcut modifiers to the event-tap representation and compares
/// the complete chord. Keeping this pure makes the "extra modifier" rule testable.
public enum HotKeyModifierMatcher {
    public static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
        .maskAlphaShift
    ]

    public static func eventFlags(forCarbonModifiers modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(alphaLock) != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    public static func matches(eventFlags: CGEventFlags, requiredFlags: CGEventFlags) -> Bool {
        eventFlags.intersection(relevantFlags) == requiredFlags.intersection(relevantFlags)
    }
}
