import XCTest
@testable import ResAICore

final class AppAutomationPolicyTests: XCTestCase {
    func testBrowsersPreferClipboardPaste() {
        let apps = [
            AppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 1),
            AppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 2),
            AppInfo(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", processIdentifier: 3)
        ]

        for app in apps {
            XCTAssertTrue(AppAutomationPolicy.prefersClipboardPaste(for: app), app.name)
        }
    }

    func testMessengerAppsPreferClipboardPaste() {
        let apps = [
            AppInfo(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 4),
            AppInfo(name: "Facebook Messenger", bundleIdentifier: "com.apple.Safari", processIdentifier: 5),
            AppInfo(name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams2", processIdentifier: 6)
        ]

        for app in apps {
            XCTAssertTrue(AppAutomationPolicy.prefersClipboardPaste(for: app), app.name)
        }
    }

    func testNativeTextEditorsCanUseAccessibilityReplacement() {
        let app = AppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 7)

        XCTAssertFalse(AppAutomationPolicy.prefersClipboardPaste(for: app))
    }
}
