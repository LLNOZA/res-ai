import XCTest
@testable import ResAICore
@testable import ResponseAi

@MainActor
final class AppControllerPermissionPromptTests: XCTestCase {
    func testPassiveObservationNeverRequestsSystemPermission() async {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        controller.observeHotKeyPermissionsIfNeeded()
        await Task.yield()

        XCTAssertEqual(probe.accessibilityRequestCount, 0)
        XCTAssertEqual(probe.inputMonitoringRequestCount, 0)
        XCTAssertTrue(probe.openedSettingsURLs.isEmpty)
    }

    func testBlockedFeatureAttemptsNeverRequestSystemPermission() async {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        controller.rewriteFocusedDraft()
        controller.fillFormFromProfile()
        await Task.yield()

        XCTAssertEqual(probe.accessibilityRequestCount, 0)
        XCTAssertEqual(probe.inputMonitoringRequestCount, 0)
        XCTAssertTrue(probe.openedSettingsURLs.isEmpty)
    }

    func testExplicitUserActionRequestsOnlyTheNextMissingPermission() {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        controller.requestHotKeyPermissionsFromUserAction(showAlert: false)

        XCTAssertEqual(probe.accessibilityRequestCount, 1)
        XCTAssertEqual(probe.inputMonitoringRequestCount, 0)
        XCTAssertEqual(probe.openedSettingsURLs.count, 1)
    }

    func testPassiveMonitorDoesNotAdvanceIntoInputMonitoringRequest() async throws {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        controller.observeHotKeyPermissionsIfNeeded()
        probe.accessibilityGranted = true
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(probe.accessibilityRequestCount, 0)
        XCTAssertEqual(probe.inputMonitoringRequestCount, 0)
        XCTAssertTrue(probe.openedSettingsURLs.isEmpty)
    }

    func testExplicitOnboardingRequestsInputMonitoringOnlyOnceAfterAccessibility() async throws {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        controller.requestHotKeyPermissionsFromUserAction(showAlert: false)
        // A feature/lifecycle status check must not downgrade or cancel the
        // user-initiated onboarding session while System Settings is open.
        controller.observeHotKeyPermissionsIfNeeded()
        probe.accessibilityGranted = true
        try await Task.sleep(for: .seconds(2.2))

        XCTAssertEqual(probe.accessibilityRequestCount, 1)
        XCTAssertEqual(probe.inputMonitoringRequestCount, 1)
        XCTAssertEqual(probe.openedSettingsURLs.count, 2)
    }

    func testMonitorStillDetectsGrantAfterTheFastPhaseEnds() async throws {
        let probe = PermissionProbe()
        let controller = makeController(
            probe: probe,
            schedule: PermissionPollSchedule(
                fastAttempts: 2,
                fastInterval: .milliseconds(10),
                slowInterval: .milliseconds(50),
                slowLogEvery: 10
            )
        )
        defer { controller.shutDown() }

        controller.observeHotKeyPermissionsIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.hotKeyPermissionsAreGranted)

        var shortcutsConfigured = false
        controller.onHotKeyPermissionsGranted = {
            shortcutsConfigured = true
            return true
        }
        probe.accessibilityGranted = true
        probe.inputMonitoringGranted = true
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(shortcutsConfigured)
    }

    func testAccessibilityRequestIsRememberedAndGrantIsRecordedWithSigningIdentity() async throws {
        let probe = PermissionProbe()
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        XCTAssertEqual(controller.accessibilityGrantDiagnosis, .notYetGranted)
        controller.requestHotKeyPermissionsFromUserAction(showAlert: false)
        XCTAssertTrue(probe.grantHistory.hasRequestedAccessibilityBefore)
        XCTAssertEqual(controller.accessibilityGrantDiagnosis, .staleGrantLikely(.requestedButNeverApplied))

        probe.accessibilityGranted = true
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(probe.grantHistory.lastGrantedSigningFingerprint, PermissionProbe.signingIdentity.fingerprint)
        XCTAssertFalse(probe.grantHistory.hasRequestedAccessibilityBefore)
    }

    func testGrantMadeForAnotherSigningIdentityIsDiagnosedAsStale() {
        let probe = PermissionProbe()
        probe.grantHistory.recordGranted(signingFingerprint: "team=OLDTEAM signer=old", version: "0.3.3 (12)")
        let controller = makeController(probe: probe)
        defer { controller.shutDown() }

        XCTAssertEqual(controller.accessibilityGrantDiagnosis, .staleGrantLikely(.signingIdentityChanged))
    }

    private var environments: [AppEnvironment] = []

    override func tearDown() async throws {
        for environment in environments {
            environment.discard()
        }
        environments.removeAll()
        try await super.tearDown()
    }

    private func makeController(probe: PermissionProbe, schedule: PermissionPollSchedule = .standard) -> AppController {
        let environment = AppEnvironment.isolated(openURL: { url in
            probe.openedSettingsURLs.append(url)
            return true
        })
        environments.append(environment)
        return AppController(
            permissionManager: probe.makeManager(),
            environment: environment,
            grantHistory: probe.grantHistory,
            signingIdentity: PermissionProbe.signingIdentity,
            permissionPollSchedule: schedule
        )
    }
}

private final class PermissionProbe {
    var accessibilityGranted = false
    var inputMonitoringGranted = false
    var accessibilityRequestCount = 0
    var inputMonitoringRequestCount = 0
    var openedSettingsURLs: [URL] = []

    static let signingIdentity = CodeSigningIdentity(teamID: "TESTTEAM", signerName: "Developer ID Application: Test (TESTTEAM)", isAdHoc: false)
    private let suiteName = "AppControllerPermissionPromptTests.\(UUID().uuidString)"
    private(set) lazy var grantHistory = AccessibilityGrantHistory(defaults: UserDefaults(suiteName: suiteName)!)

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func makeManager() -> AccessibilityPermissionManager {
        AccessibilityPermissionManager(
            accessibilityTrustCheck: { [weak self] in
                self?.accessibilityGranted == true
            },
            accessibilityPromptRequest: { [weak self] in
                guard let self else { return false }
                accessibilityRequestCount += 1
                return accessibilityGranted
            },
            inputMonitoringAccessCheck: { [weak self] in
                self?.inputMonitoringGranted == true
            },
            inputMonitoringAccessRequest: { [weak self] in
                guard let self else { return false }
                inputMonitoringRequestCount += 1
                return inputMonitoringGranted
            }
        )
    }
}
