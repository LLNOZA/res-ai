import XCTest
@testable import ResAICore

final class MenuBarIconVisibilityTests: XCTestCase {
    func testNotchGapUsesAuxiliaryAreaMaxXToMinX() {
        let left = CGRect(x: 0, y: 950, width: 620, height: 32)
        let right = CGRect(x: 892, y: 950, width: 620, height: 32)
        XCTAssertEqual(MenuBarIconVisibility.notchGapXRange(leftArea: left, rightArea: right), 620..<892)
    }

    func testNotchGapNilWhenAreasAreEmptyOrOverlap() {
        XCTAssertNil(MenuBarIconVisibility.notchGapXRange(leftArea: nil, rightArea: nil))
        XCTAssertNil(
            MenuBarIconVisibility.notchGapXRange(leftArea: .zero, rightArea: CGRect(x: 800, y: 0, width: 100, height: 32))
        )
        let left = CGRect(x: 0, y: 0, width: 1512, height: 32)
        let right = CGRect(x: 1400, y: 0, width: 112, height: 32)
        XCTAssertNil(MenuBarIconVisibility.notchGapXRange(leftArea: left, rightArea: right))
    }

    func testHiddenWhenWindowIsNil() {
        XCTAssertTrue(
            MenuBarIconVisibility.isHidden(
                windowExists: false,
                occlusionContainsVisible: true,
                windowFrame: CGRect(x: 20, y: 980, width: 22, height: 22),
                notchGapXRange: 620..<892
            )
        )
    }

    func testHiddenWhenOcclusionLacksVisible() {
        XCTAssertTrue(
            MenuBarIconVisibility.isHidden(
                windowExists: true,
                occlusionContainsVisible: false,
                windowFrame: CGRect(x: 20, y: 980, width: 22, height: 22),
                notchGapXRange: 620..<892
            )
        )
    }

    func testHiddenWhenFrameIntersectsNotchGap() {
        // MacBook Pro 14" (1512 pt): status item under the notch around x≈798.
        let frame = CGRect(x: 798, y: 980, width: 22, height: 22)
        XCTAssertTrue(MenuBarIconVisibility.intersects(frame, gap: 620..<892))
        XCTAssertTrue(
            MenuBarIconVisibility.isHidden(
                windowExists: true,
                occlusionContainsVisible: true,
                windowFrame: frame,
                notchGapXRange: 620..<892
            )
        )
    }

    func testVisibleWhenFrameIsOutsideNotchGap() {
        let frame = CGRect(x: 1480, y: 980, width: 22, height: 22)
        XCTAssertFalse(MenuBarIconVisibility.intersects(frame, gap: 620..<892))
        XCTAssertFalse(
            MenuBarIconVisibility.isHidden(
                windowExists: true,
                occlusionContainsVisible: true,
                windowFrame: frame,
                notchGapXRange: 620..<892
            )
        )
    }
}
