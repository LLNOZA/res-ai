import XCTest
@testable import ResAICore

final class VoiceInputSettingsTests: XCTestCase {
    func testCleanupTimeoutDefaultsToSixSeconds() {
        let suiteName = "VoiceInputSettingsTests.timeout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceInputSettings().cleanupTimeoutSeconds, 6.0)
        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).cleanupTimeoutSeconds, 6.0)
    }

    func testActivationModeDefaultsToToggleOnlyWhenKeyIsAbsent() {
        let suiteName = "VoiceInputSettingsTests.absent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = VoiceInputSettings.load(defaults: defaults)
        XCTAssertEqual(settings.activationMode, .toggleOnly)
        XCTAssertNil(defaults.object(forKey: VoiceInputSettings.DefaultsKey.activationMode))
    }

    func testActivationModeRoundTripsThroughUserDefaults() {
        let suiteName = "VoiceInputSettingsTests.roundTrip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = VoiceInputSettings.load(defaults: defaults)
        settings.activationMode = .holdOrTap
        settings.save(defaults: defaults)

        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).activationMode, .holdOrTap)

        settings.activationMode = .toggleOnly
        settings.save(defaults: defaults)
        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).activationMode, .toggleOnly)
    }

    func testInvalidStoredActivationModeFallsBackToToggleOnly() {
        let suiteName = "VoiceInputSettingsTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-mode", forKey: VoiceInputSettings.DefaultsKey.activationMode)
        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).activationMode, .toggleOnly)
    }

    func testCleanupStyleDefaultsToRewriteAndRoundTrips() {
        let suiteName = "VoiceInputSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).cleanupStyle, .rewrite)

        var settings = VoiceInputSettings()
        settings.cleanupStyle = .light
        settings.save(defaults: defaults)
        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).cleanupStyle, .light)

        defaults.set("bogus", forKey: VoiceInputSettings.DefaultsKey.cleanupStyle)
        XCTAssertEqual(VoiceInputSettings.load(defaults: defaults).cleanupStyle, .rewrite)
    }
}
