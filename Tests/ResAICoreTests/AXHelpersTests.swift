import CoreFoundation
import XCTest
@testable import ResAICore

final class AXHelpersTests: XCTestCase {
    func testSafeCastReturnsNilOnWrongType() {
        let string = "not an AX element" as CFString
        XCTAssertNil(AXHelpers.uiElement(from: string))
        XCTAssertNil(AXHelpers.axValue(from: string))
    }

    func testSafeCastAcceptsAXValue() {
        var range = CFRange(location: 1, length: 2)
        guard let value = AXValueCreate(.cfRange, &range) else {
            XCTFail("AXValueCreate failed")
            return
        }
        XCTAssertNotNil(AXHelpers.axValue(from: value))
        XCTAssertNil(AXHelpers.uiElement(from: value))
    }
}
