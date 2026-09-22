import CoreGraphics
import XCTest
@testable import ResAICore

final class ModifierChordDetectorTests: XCTestCase {
    private let chord: CGEventFlags = [.maskSecondaryFn, .maskCommand]

    func testPressWhenBothFlagsAppearAndReleaseWhenEitherDrops() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: [.maskSecondaryFn], at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .pressed)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .none)
        XCTAssertEqual(detector.handle(flags: [.maskCommand], at: 1.50), .released)
        XCTAssertEqual(detector.handle(flags: [], at: 1.51), .none)
    }

    func testDebouncesSecondPressWithin150ms() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handle(flags: [], at: 1.05), .released)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.10), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.16), .pressed)
    }

    func testExtraModifiersDoNotMatch() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(
            detector.handle(flags: [.maskSecondaryFn, .maskCommand, .maskShift], at: 1.0),
            .none
        )
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .pressed)
    }

    func testExtraKeyCancelsPressWithin300ms() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handleNonModifierKeyDown(at: 1.20), .released)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.21), .none)
        detector.handleNonModifierKeyUp()
    }

    func testExtraKeyAfterCancelWindowDoesNotRelease() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertEqual(detector.handleNonModifierKeyDown(at: 1.31), .none)
        XCTAssertEqual(detector.handle(flags: [], at: 2.0), .released)
    }

    func testDoesNotPressWhileNonModifierKeyIsDown() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handleNonModifierKeyDown(at: 1.0), .none)
        XCTAssertEqual(detector.handle(flags: chord, at: 1.01), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .pressed)
    }

    func testResetReportsHeldChordAndClearsDebounceAndExtraKeyState() {
        var detector = ModifierChordDetector(requiredFlags: chord)

        XCTAssertEqual(detector.handle(flags: chord, at: 1.0), .pressed)
        XCTAssertTrue(detector.reset())
        XCTAssertFalse(detector.reset())
        XCTAssertEqual(detector.handleNonModifierKeyDown(at: 1.01), .none)
        detector.handleNonModifierKeyUp()
        XCTAssertEqual(detector.handle(flags: chord, at: 1.02), .pressed)
    }
}
