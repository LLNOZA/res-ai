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

    func testCommandOnlyAndCommandShiftRemainDistinct() {
        let command = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey))
        let commandShift = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: UInt32(cmdKey | shiftKey))

        XCTAssertTrue(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand], requiredFlags: command))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand, .maskShift], requiredFlags: command))
        XCTAssertFalse(HotKeyModifierMatcher.matches(eventFlags: [.maskCommand], requiredFlags: commandShift))
    }
}
