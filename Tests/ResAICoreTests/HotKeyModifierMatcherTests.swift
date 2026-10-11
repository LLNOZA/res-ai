import Carbon
import CoreGraphics
import XCTest
@testable import ResAICore

final class HotKeyModifierMatcherTests: XCTestCase {
    func testAdditionalOptionControlFunctionAndCapsLockDoNotMatch() {
        let required = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey | shiftKey))

        XCTAssertTrue(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift], requiredFlags: required))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift, .maskAlternate], requiredFlags: required))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift, .maskControl], requiredFlags: required))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift, .maskSecondaryFn], requiredFlags: required))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift, .maskAlphaShift], requiredFlags: required))
    }

    func testFnFlagIsIgnoredOnlyForKeysWhereMacOSSetsIt() {
        let required = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey | controlKey))

        XCTAssertTrue(HotKeyModifierMatcher.matches(
            eventFlags: [.maskCommand, .maskControl, .maskSecondaryFn],
            requiredFlags: required,
            keyCode: UInt32(kVK_LeftArrow)
        ))
        XCTAssertTrue(HotKeyModifierMatcher.matches(
            eventFlags: [.maskSecondaryFn],
            requiredFlags: [],
            keyCode: UInt32(kVK_F5)
        ))
        XCTAssertFalse(HotKeyModifierMatcher.matches(
            eventFlags: [.maskCommand, .maskControl, .maskSecondaryFn],
            requiredFlags: required,
            keyCode: UInt32(kVK_ANSI_J)
        ))
        XCTAssertFalse(HotKeyModifierMatcher.matches(
            eventFlags: [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn],
            requiredFlags: required,
            keyCode: UInt32(kVK_LeftArrow)
        ))
    }

    func testCommandOnlyAndCommandShiftRemainDistinct() {
        let command = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey))
        let commandShift = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey | shiftKey))

        XCTAssertTrue(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand], requiredFlags: command))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift], requiredFlags: command))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand], requiredFlags: commandShift))
    }
}
