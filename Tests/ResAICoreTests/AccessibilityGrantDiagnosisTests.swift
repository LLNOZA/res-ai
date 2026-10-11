import XCTest
@testable import ResAICore

final class AccessibilityGrantDiagnosisTests: XCTestCase {
    private let current = "team=NEWTEAM signer=Developer ID Application: Example (NEWTEAM)"
    private let previous = "team=OLDTEAM signer=Apple Development: Someone (OLDID)"

    func testTrustedAccessibilityIsGrantedRegardlessOfHistory() {
        XCTAssertEqual(diagnose(trusted: true, inputMonitoring: false, lastGranted: previous, requested: true), .granted)
    }

    func testGrantFromDifferentSigningIdentityIsStale() {
        XCTAssertEqual(
            diagnose(trusted: false, inputMonitoring: false, lastGranted: previous, requested: false),
            .staleGrantLikely(.signingIdentityChanged)
        )
    }

    func testLostGrantForSameSigningIdentityIsStale() {
        XCTAssertEqual(
            diagnose(trusted: false, inputMonitoring: false, lastGranted: current, requested: false),
            .staleGrantLikely(.previouslyGranted)
        )
    }

    func testInputMonitoringWithoutAccessibilityIsStaleEvenWithoutHistory() {
        // The field case: grants made before history existed, Input Monitoring re-registered, Accessibility not.
        XCTAssertEqual(
            diagnose(trusted: false, inputMonitoring: true, lastGranted: nil, requested: false),
            .staleGrantLikely(.inputMonitoringGrantedWithoutAccessibility)
        )
    }

    func testRequestThatNeverAppliedIsStale() {
        XCTAssertEqual(
            diagnose(trusted: false, inputMonitoring: false, lastGranted: nil, requested: true),
            .staleGrantLikely(.requestedButNeverApplied)
        )
    }

    func testFreshInstallIsNotYetGranted() {
        let diagnosis = diagnose(trusted: false, inputMonitoring: false, lastGranted: nil, requested: false)
        XCTAssertEqual(diagnosis, .notYetGranted)
        XCTAssertFalse(diagnosis.isStaleGrantLikely)
    }

    func testHistoryRecordsGrantAndClearsPendingRequest() {
        let (defaults, cleanUp) = makeDefaults()
        defer { cleanUp() }
        let history = AccessibilityGrantHistory(defaults: defaults)

        history.recordAccessibilityRequested()
        XCTAssertTrue(history.hasRequestedAccessibilityBefore)

        history.recordGranted(signingFingerprint: current, version: "0.4.2 (17)")
        XCTAssertEqual(history.lastGrantedSigningFingerprint, current)
        XCTAssertEqual(history.lastGrantedVersion, "0.4.2 (17)")
        XCTAssertFalse(history.hasRequestedAccessibilityBefore)
    }

    func testRecordLaunchReturnsPreviousIdentityOnlyWhenItChanged() {
        let (defaults, cleanUp) = makeDefaults()
        defer { cleanUp() }
        let history = AccessibilityGrantHistory(defaults: defaults)

        XCTAssertNil(history.recordLaunch(signingFingerprint: previous))
        XCTAssertNil(history.recordLaunch(signingFingerprint: previous))
        XCTAssertEqual(history.recordLaunch(signingFingerprint: current), previous)
        XCTAssertNil(history.recordLaunch(signingFingerprint: current))
    }

    func testSigningFingerprintDistinguishesAdHocUnsignedAndTeamSignatures() {
        XCTAssertEqual(CodeSigningIdentity(teamID: nil, signerName: nil, isAdHoc: true).fingerprint, "adhoc")
        XCTAssertEqual(CodeSigningIdentity.unsigned.fingerprint, "unsigned")
        XCTAssertNotEqual(
            CodeSigningIdentity(teamID: "AAA", signerName: "Apple Development: A (1)", isAdHoc: false).fingerprint,
            CodeSigningIdentity(teamID: "BBB", signerName: "Apple Development: B (2)", isAdHoc: false).fingerprint
        )
    }

    private func diagnose(trusted: Bool, inputMonitoring: Bool, lastGranted: String?, requested: Bool) -> AccessibilityGrantDiagnosis {
        AccessibilityGrantDiagnosis.diagnose(
            accessibilityTrusted: trusted,
            inputMonitoringGranted: inputMonitoring,
            currentSigningFingerprint: current,
            lastGrantedSigningFingerprint: lastGranted,
            hasRequestedAccessibilityBefore: requested
        )
    }

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "AccessibilityGrantDiagnosisTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

final class PermissionPollScheduleTests: XCTestCase {
    func testStandardScheduleKeepsPollingSlowlyAfterTheFastPhase() {
        let schedule = PermissionPollSchedule.standard

        XCTAssertEqual(schedule.interval(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(schedule.interval(afterAttempt: 119), .seconds(1))
        XCTAssertEqual(schedule.interval(afterAttempt: 120), .seconds(30))
        XCTAssertEqual(schedule.interval(afterAttempt: 10_000), .seconds(30))
        XCTAssertTrue(schedule.isFastPhaseEnd(120))
        XCTAssertFalse(schedule.isFastPhaseEnd(121))
    }

    func testLoggingIsSparseInBothPhases() {
        let schedule = PermissionPollSchedule.standard

        XCTAssertTrue(schedule.shouldLog(attempt: 1))
        XCTAssertTrue(schedule.shouldLog(attempt: 10))
        XCTAssertFalse(schedule.shouldLog(attempt: 11))
        XCTAssertFalse(schedule.shouldLog(attempt: 125))
        XCTAssertTrue(schedule.shouldLog(attempt: 130))
    }
}
