import Foundation

/// Why Accessibility is missing. A grant made for a different signing identity
/// stays listed and switched on in System Settings but no longer applies; toggling
/// it does nothing, and only removing the entry and adding the app again helps.
public enum AccessibilityGrantDiagnosis: Equatable, Sendable {
    case granted
    case notYetGranted
    case staleGrantLikely(StaleAccessibilityGrantReason)

    public static func diagnose(
        accessibilityTrusted: Bool,
        inputMonitoringGranted: Bool,
        currentSigningFingerprint: String,
        lastGrantedSigningFingerprint: String?,
        hasRequestedAccessibilityBefore: Bool
    ) -> AccessibilityGrantDiagnosis {
        if accessibilityTrusted {
            return .granted
        }
        if let lastGrantedSigningFingerprint {
            return .staleGrantLikely(
                lastGrantedSigningFingerprint == currentSigningFingerprint
                    ? .previouslyGranted
                    : .signingIdentityChanged
            )
        }
        // Input Monitoring re-registers through its own prompt, while an existing
        // Accessibility entry keeps the old signature, so this split is typical of a stale grant.
        if inputMonitoringGranted {
            return .staleGrantLikely(.inputMonitoringGrantedWithoutAccessibility)
        }
        if hasRequestedAccessibilityBefore {
            return .staleGrantLikely(.requestedButNeverApplied)
        }
        return .notYetGranted
    }

    public var isStaleGrantLikely: Bool {
        if case .staleGrantLikely = self {
            return true
        }
        return false
    }

    public var logLabel: String {
        switch self {
        case .granted:
            "granted"
        case .notYetGranted:
            "not-yet-granted"
        case .staleGrantLikely(let reason):
            "stale-grant-likely:\(reason.rawValue)"
        }
    }
}

public enum StaleAccessibilityGrantReason: String, Equatable, Sendable {
    case signingIdentityChanged = "signing-identity-changed"
    case previouslyGranted = "previously-granted"
    case inputMonitoringGrantedWithoutAccessibility = "input-monitoring-only"
    case requestedButNeverApplied = "requested-never-applied"
}

/// Remembers which signing identity last held Accessibility, and which one last
/// launched, so a lost grant can be explained instead of re-requested blindly.
public final class AccessibilityGrantHistory {
    enum DefaultsKey {
        static let lastGrantedSigning = "permissions.accessibility.lastGrantedSigning"
        static let lastGrantedVersion = "permissions.accessibility.lastGrantedVersion"
        static let requestedWhileUntrusted = "permissions.accessibility.requestedWhileUntrusted"
        static let lastLaunchSigning = "app.lastLaunchSigning"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastGrantedSigningFingerprint: String? {
        defaults.string(forKey: DefaultsKey.lastGrantedSigning)
    }

    public var lastGrantedVersion: String? {
        defaults.string(forKey: DefaultsKey.lastGrantedVersion)
    }

    public var hasRequestedAccessibilityBefore: Bool {
        defaults.bool(forKey: DefaultsKey.requestedWhileUntrusted)
    }

    public func recordGranted(signingFingerprint: String, version: String) {
        defaults.set(signingFingerprint, forKey: DefaultsKey.lastGrantedSigning)
        defaults.set(version, forKey: DefaultsKey.lastGrantedVersion)
        defaults.removeObject(forKey: DefaultsKey.requestedWhileUntrusted)
    }

    public func recordAccessibilityRequested() {
        defaults.set(true, forKey: DefaultsKey.requestedWhileUntrusted)
    }

    /// Stores this launch's identity and returns the previous one when it differs.
    @discardableResult
    public func recordLaunch(signingFingerprint: String) -> String? {
        let previous = defaults.string(forKey: DefaultsKey.lastLaunchSigning)
        defaults.set(signingFingerprint, forKey: DefaultsKey.lastLaunchSigning)
        guard let previous, previous != signingFingerprint else {
            return nil
        }
        return previous
    }
}
