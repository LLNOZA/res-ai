import Foundation

/// Why a keyboard-based cleanup swap must not run.
public enum KeyboardSwapSkipReason: Equatable, Sendable {
    case userTypedOrClicked
    case insertedTextTooLong
    case appNotFrontmost
    case focusMismatch
    case pasteFailed

    public var logLabel: String {
        switch self {
        case .userTypedOrClicked:
            "user typed or clicked"
        case .insertedTextTooLong:
            "inserted text over 400 chars"
        case .appNotFrontmost:
            "app not frontmost"
        case .focusMismatch:
            "focused element mismatch"
        case .pasteFailed:
            "paste failed"
        }
    }
}

/// Pure helper for the keyboard cleanup swap: Shift+Left count and the 400-character cap.
public enum KeyboardSwapPlan {
    public static let maxInsertedCharacterCount = 400

    /// Number of ⇧← presses needed to select `insertedText` (Swift `Character` count).
    /// Newlines count as one. Returns `nil` when the text is over 400 characters.
    public static func shiftLeftCount(for insertedText: String) -> Int? {
        let count = insertedText.count
        guard count <= maxInsertedCharacterCount else {
            return nil
        }
        return count
    }
}
