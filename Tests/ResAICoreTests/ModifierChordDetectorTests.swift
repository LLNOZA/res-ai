import CoreGraphics
import XCTest
@testable import ResAICore

final class ModifierChordDetectorTests: XCTestCase {
    private let chord: CGEventFlags = [.maskSecondaryFn, .maskCommand]
    private let commandShift: CGEventFlags = [.maskCommand, .maskShift]

    // MARK: Tap style (every action except hold-mode voice)

    func testTapFiresWhenChordIsPressedAloneAndReleased() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: [.maskSecondaryFn], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .none)
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.20), .tapped)
        XCTAssertEqual(detector.handle(flags: [], at: 1.21), .none)
    }

    func testTapWorksForEverySingleModifier() {
        let singles: [CGEventFlags] = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        for flags in singles {
            var detector = ModifierChordDetector(requiredFlags: flags)
            XCTAssertEqual(detector.handle(flags: flags, at: 1.0), .none, "\(flags)")
            XCTAssertEqual(detector.handle(flags: [], at: 1.1), .tapped, "\(flags)")
        }
    }

    func testTapDoesNotFireWhenOrdinaryKeyIsPressedWhileHeld() {
        var detector = ModifierChordDetector(requiredFlags: commandShift)

        // ⌘⇧T: the chord is complete, then T.
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.0), .none)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.2), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.25), .none)
    }

    func testTapDoesNotFireWhenOrdinaryKeyIsPressedWhileBuildingTheChord() {
        var detector = ModifierChordDetector(requiredFlags: commandShift)

        // ⌘ down, T down, ⇧ down (⌘T, then ⇧ joins).
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.0), .none)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.10), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.20), .none)
    }

    func testTapDoesNotFireAfterMouseClickWhileHeld() {
        var detector = ModifierChordDetector(requiredFlags: [.maskCommand])

        // ⌘-click.
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.0), .none)
        XCTAssertEqual(detector.handleMouseDown(), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.2), .none)
    }

    func testTapDoesNotFireWhenHeldLongerThanLimit() {
        var detector = ModifierChordDetector(requiredFlags: [.maskControl])

        XCTAssertEqual(detector.handle(flags: [.maskControl], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.61), .none)

        // Within the limit it fires again.
        XCTAssertEqual(detector.handle(flags: [.maskControl], at: 2.0), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 2.59), .tapped)
    }

    func testTapDoesNotFireWhenAnotherModifierJoins() {
        var detector = ModifierChordDetector(requiredFlags: commandShift)

        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: [.maskCommand, .maskShift, .maskAlternate], at: 1.1), .none)
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.2), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.3), .none)
    }

    func testChordReachedByReleasingAnExtraModifierDoesNotCount() {
        var detector = ModifierChordDetector(requiredFlags: [.maskCommand])

        // ⇧ first, then ⌘, then ⇧ up leaves ⌘ alone: not a ⌘ tap.
        XCTAssertEqual(detector.handle(flags: [.maskShift], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.1), .none)
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.2), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.3), .none)
    }

    func testRepressingAReleasedModifierNeedsEverythingUpFirst() {
        var detector = ModifierChordDetector(requiredFlags: commandShift)

        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.1), .tapped)
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.2), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.3), .none)
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.4), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.5), .tapped)
    }

    func testKeySwallowedByAnotherShortcutPreventsTap() {
        var detector = ModifierChordDetector(requiredFlags: commandShift)

        // ⌘⇧J where J belongs to another shortcut's tap.
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.0), .none)
        XCTAssertEqual(detector.handleKeySwallowedElsewhere(), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.2), .none)
    }

    func testCapsLockDoesNotBlockTheChord() {
        var detector = ModifierChordDetector(requiredFlags: [.maskControl])

        XCTAssertEqual(detector.handle(flags: [.maskControl, .maskAlphaShift], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: [.maskAlphaShift], at: 1.1), .tapped)
    }

    func testDoesNotArmWhileNonModifierKeyIsDown() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.05), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: chord, at: 1.10), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.20), .tapped)
    }

    // MARK: Hold style (voice in hold mode)

    func testHoldPressesWhenChordCompletesAndReleasesWhenEitherDrops() {
        var detector = ModifierChordDetector(requiredFlags: chord, style: .hold)

        XCTAssertEqual(detector.handle(flags: [.maskSecondaryFn], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .pressed)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .none)
        // Long holds are fine for push-to-talk.
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 3.0), .released)
        XCTAssertEqual(detector.handle(flags: [], at: 3.01), .none)
    }

    func testHoldDebouncesSecondPressWithin150ms() {
        var detector = ModifierChordDetector(requiredFlags: chord, style: .hold)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handle(flags: [], at: 1.05), .released)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.10), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.12), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.16), .pressed)
    }

    func testHoldCancelsExactlyOnceWhenOrdinaryKeyArrives() {
        var detector = ModifierChordDetector(requiredFlags: commandShift, style: .hold)

        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.0), .pressed)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .cancelled)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        detector.handleNonModifierKeyUp()
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.3), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.4), .none)
    }

    func testHoldCancelsLateKeysToo() {
        var detector = ModifierChordDetector(requiredFlags: chord, style: .hold)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .cancelled)
    }

    func testHoldCancelsWhenAnotherModifierJoins() {
        var detector = ModifierChordDetector(requiredFlags: [.maskCommand], style: .hold)

        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.0), .pressed)
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.1), .cancelled)
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.2), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.3), .none)
    }

    func testHoldKeepsListeningThroughMouseClicks() {
        var detector = ModifierChordDetector(requiredFlags: chord, style: .hold)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handleMouseDown(), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 2.0), .released)
    }

    func testHoldDoesNotPressWhenOrdinaryKeyCameWhileBuildingTheChord() {
        var detector = ModifierChordDetector(requiredFlags: commandShift, style: .hold)

        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.0), .none)
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: commandShift, at: 1.10), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 1.20), .none)
    }

    func testResetReportsHeldChordAndClearsDebounceAndExtraKeyState() {
        var detector = ModifierChordDetector(requiredFlags: chord, style: .hold)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertTrue(detector.reset())
        XCTAssertFalse(detector.reset())
        XCTAssertEqual(detector.handleNonModifierKeyDown(), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .pressed)
    }

    func testActivationModeMapsToChordStyle() {
        XCTAssertEqual(VoiceActivationMode.toggleOnly.modifierChordStyle, .tap)
        XCTAssertEqual(VoiceActivationMode.holdOrTap.modifierChordStyle, .hold)
    }
}
