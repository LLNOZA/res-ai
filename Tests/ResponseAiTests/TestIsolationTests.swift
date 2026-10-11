import AppKit
import XCTest
@testable import ResAICore
@testable import ResponseAi

/// A test run must never write the user's log, settings, Keychain, or clipboard,
/// or open System Settings.
@MainActor
final class TestIsolationTests: XCTestCase {
    func testLogGoesToTemporaryDirectory() throws {
        let realLogs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ResponseAi").standardizedFileURL.path
        let logDirectory = AppLog.logDirectory.standardizedFileURL.path
        XCTAssertTrue(AppRuntime.isRunningUnitTests)
        XCTAssertFalse(logDirectory.hasPrefix(realLogs))
        XCTAssertTrue(logDirectory.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))

        let marker = "isolation marker \(UUID().uuidString)"
        AppLog.write(marker)
        AppLog.flushSync()
        let written = try String(contentsOf: AppLog.logURL, encoding: .utf8)
        XCTAssertTrue(written.contains(marker))
    }

    func testDefaultEnvironmentInsideTestsIsIsolated() throws {
        let environment = AppEnvironment.current
        defer { environment.discard() }
        XCTAssertNotNil(environment.temporarySuiteName)
        XCTAssertNotEqual(environment.pasteboard.name, NSPasteboard.general.name)
        XCTAssertTrue(environment.secretStore is InMemorySecretStore)
        XCTAssertFalse(environment.openURL(try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.preference.security"))))
    }

    func testControllerWritesOnlyToItsEnvironment() throws {
        let generalChangeCount = NSPasteboard.general.changeCount
        let environment = AppEnvironment.isolated()
        defer { environment.discard() }
        let controller = AppController(
            permissionManager: AccessibilityPermissionManager(
                accessibilityTrustCheck: { false },
                accessibilityPromptRequest: { false },
                inputMonitoringAccessCheck: { false },
                inputMonitoringAccessRequest: { false }
            ),
            environment: environment
        )
        defer { controller.shutDown() }

        controller.claudeAPIKeyInput = "test-placeholder-key"
        XCTAssertTrue(controller.saveClaudeAPIKey())
        XCTAssertEqual(try environment.secretStore.string(for: ClaudeAPIKeyStore.account), "test-placeholder-key")
        controller.deleteClaudeAPIKey()
        XCTAssertNil(try environment.secretStore.string(for: ClaudeAPIKeyStore.account))

        controller.userProfileEnabled = false
        controller.saveUserProfile()
        XCTAssertEqual(environment.defaults.object(forKey: UserProfile.DefaultsKey.isEnabled) as? Bool, false)

        environment.pasteboard.setString("isolated copy", forType: .string)
        controller.startClipboardHistoryMonitoring()
        XCTAssertEqual(controller.clipboardHistory.items.first?.text, "isolated copy")
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount)
    }
}

@MainActor
final class CrashDiagnosticsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try await super.tearDown()
    }

    func testSessionExitTrackerDetectsUnexpectedExit() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = SessionExitTracker(defaults: defaults)
        let started = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(tracker.beginSession(version: "0.4.2 (17)", now: started), .firstLaunch)
        // No endSession: the process crashed or was killed.
        XCTAssertEqual(
            tracker.beginSession(version: "0.4.2 (17)"),
            .unexpected(startedAt: started, version: "0.4.2 (17)")
        )
        tracker.endSession()
        XCTAssertEqual(tracker.beginSession(version: "0.4.2 (17)"), .clean)
        XCTAssertTrue(SessionExitTracker.logLine(for: .unexpected(startedAt: nil, version: nil)).contains("unexpectedly"))
    }

    func testMetricKitPayloadIsSavedOnceWithoutMessages() throws {
        let directory = makeTemporaryDirectory()
        let payload = try JSONSerialization.data(withJSONObject: [
            "timeStampEnd": "2026-10-11 10:00:00",
            "crashDiagnostics": [[
                "diagnosticMetaData": [
                    "exceptionType": 6,
                    "objectiveCexceptionReason": ["composedMessage": "user text", "arguments": ["user text"], "exceptionName": "NSInternalInconsistencyException"]
                ]
            ]]
        ])

        let saved = try XCTUnwrap(MetricKitDiagnosticsRecorder.write(payloadJSON: payload, to: directory))
        let contents = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertFalse(contents.contains("user text"))
        XCTAssertTrue(contents.contains("NSInternalInconsistencyException"))
        XCTAssertNil(MetricKitDiagnosticsRecorder.write(payloadJSON: payload, to: directory), "a re-delivered payload is not duplicated")
    }

    func testExportBundlesLogDiagnosticsAndSystemSummary() throws {
        let logDirectory = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        try Data("log line\n".utf8).write(to: logDirectory.appendingPathComponent("responseai.log"))
        let diagnostics = logDirectory.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: diagnostics.appendingPathComponent("diagnostic-1.json"))

        let exporter = DiagnosticsExporter(
            logDirectory: logDirectory,
            destinationDirectory: destination,
            systemSummary: "ResponseAi test\n",
            now: Date(timeIntervalSince1970: 0)
        )
        let first = try exporter.export()
        let second = try exporter.export()
        XCTAssertNotEqual(first, second, "an existing export is never overwritten")

        let listing = try zipListing(first)
        XCTAssertTrue(listing.contains("logs/responseai.log"))
        XCTAssertTrue(listing.contains("diagnostics/diagnostic-1.json"))
        XCTAssertTrue(listing.contains("system.txt"))
    }

    func testDiagnosticsSummaryHasVersionsButNoClipboardText() throws {
        let environment = AppEnvironment.isolated()
        defer { environment.discard() }
        environment.pasteboard.setString("secret clipboard text", forType: .string)
        let controller = AppController(
            permissionManager: AccessibilityPermissionManager(
                accessibilityTrustCheck: { false },
                accessibilityPromptRequest: { false },
                inputMonitoringAccessCheck: { false },
                inputMonitoringAccessRequest: { false }
            ),
            environment: environment
        )
        defer { controller.shutDown() }
        controller.startClipboardHistoryMonitoring()

        let summary = controller.diagnosticsSummary()
        XCTAssertTrue(summary.contains("macOS "))
        XCTAssertTrue(summary.contains("items=1"))
        XCTAssertFalse(summary.contains("secret clipboard text"))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func zipListing(_ url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
