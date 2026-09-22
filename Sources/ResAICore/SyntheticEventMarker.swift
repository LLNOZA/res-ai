import CoreGraphics
import Foundation

/// Tags the CGEvents we synthesize (⌘V, ⇧←, focus clicks) so our own monitors can tell
/// them apart from real user input. Uses the user-data field, which survives the HID tap.
public enum SyntheticEventMarker {
    /// "RESAI" in ASCII.
    public static let value: Int64 = 0x5245_5341_49

    public static func tag(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: value)
    }

    public static func isSynthetic(_ event: CGEvent?) -> Bool {
        guard let event else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == value
    }
}
