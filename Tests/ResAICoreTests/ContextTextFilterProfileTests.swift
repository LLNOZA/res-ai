import XCTest
@testable import ResAICore

final class ContextTextFilterProfileTests: XCTestCase {
    func testSlackProfileExpandsCaptureArea() {
        let base = ContextTextFilter()
        let tuned = base.tuned(for: AppInfo(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            processIdentifier: 100
        ))

        XCTAssertGreaterThan(tuned.maxLines, base.maxLines)
        XCTAssertGreaterThan(tuned.verticalLookback, base.verticalLookback)
        XCTAssertGreaterThan(tuned.horizontalPadding, base.horizontalPadding)
    }

    func testBrowserProfileCoversWebMessengers() {
        let base = ContextTextFilter()
        let tuned = base.tuned(for: AppInfo(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 101
        ))

        XCTAssertGreaterThanOrEqual(tuned.maxLines, 16)
        XCTAssertGreaterThan(tuned.horizontalPadding, base.horizontalPadding)
    }

    func testEdgeUsesBrowserProfile() {
        let base = ContextTextFilter()
        let tuned = base.tuned(for: AppInfo(
            name: "Microsoft Edge",
            bundleIdentifier: "com.microsoft.edgemac",
            processIdentifier: 102
        ))

        XCTAssertGreaterThanOrEqual(tuned.maxLines, 20)
        XCTAssertGreaterThan(tuned.verticalLookback, base.verticalLookback)
        XCTAssertGreaterThan(tuned.horizontalPadding, base.horizontalPadding)
    }
}
