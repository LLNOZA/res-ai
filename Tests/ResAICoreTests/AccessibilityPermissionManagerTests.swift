import XCTest
@testable import ResAICore

final class AccessibilityPermissionManagerTests: XCTestCase {
    func testHotKeyPermissionStateCoversAllPermissionCombinations() {
        let cases: [(accessibility: Bool, inputMonitoring: Bool, expected: HotKeyPermissionState)] = [
            (true, true, .granted),
            (false, true, .accessibilityRequired),
            (true, false, .inputMonitoringRequired),
            (false, false, .accessibilityAndInputMonitoringRequired)
        ]

        for testCase in cases {
            let manager = AccessibilityPermissionManager(
                accessibilityTrustCheck: { testCase.accessibility },
                accessibilityPromptRequest: { false },
                inputMonitoringAccessCheck: { testCase.inputMonitoring },
                inputMonitoringAccessRequest: { false }
            )

            XCTAssertEqual(manager.isTrusted, testCase.accessibility)
            XCTAssertEqual(manager.isInputMonitoringEnabled, testCase.inputMonitoring)
            XCTAssertEqual(manager.hotKeyPermissionState, testCase.expected)
        }
    }

    func testPermissionRequestsCallTheirInjectedSystemFunctionsAndReturnTheirResults() {
        var accessibilityPromptRequested = false
        var inputMonitoringPermissionRequested = false
        let manager = AccessibilityPermissionManager(
            accessibilityTrustCheck: { false },
            accessibilityPromptRequest: {
                accessibilityPromptRequested = true
                return true
            },
            inputMonitoringAccessCheck: { false },
            inputMonitoringAccessRequest: {
                inputMonitoringPermissionRequested = true
                return false
            }
        )

        XCTAssertTrue(manager.requestPermissionPrompt())
        XCTAssertTrue(accessibilityPromptRequested)
        XCTAssertFalse(inputMonitoringPermissionRequested)

        XCTAssertFalse(manager.requestInputMonitoringPermission())
        XCTAssertTrue(inputMonitoringPermissionRequested)
    }
}
