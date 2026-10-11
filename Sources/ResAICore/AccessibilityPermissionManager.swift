import ApplicationServices
import Foundation

public enum HotKeyPermissionState: Equatable {
    case granted
    case accessibilityRequired
    case inputMonitoringRequired
    case accessibilityAndInputMonitoringRequired
}

public final class AccessibilityPermissionManager {
    private let accessibilityTrustCheck: () -> Bool
    private let accessibilityPromptRequest: () -> Bool
    private let inputMonitoringAccessCheck: () -> Bool
    private let inputMonitoringAccessRequest: () -> Bool

    public convenience init() {
        self.init(
            accessibilityTrustCheck: { AXIsProcessTrusted() },
            accessibilityPromptRequest: {
                // Use the literal key to avoid Swift 6 treating the imported C global
                // as unsafe shared mutable state.
                let promptKey = "AXTrustedCheckOptionPrompt"
                let options = [promptKey: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            inputMonitoringAccessCheck: { CGPreflightListenEventAccess() },
            inputMonitoringAccessRequest: { CGRequestListenEventAccess() }
        )
    }

    // Internal so tests can inject permission states without invoking system TCC UI.
    init(
        accessibilityTrustCheck: @escaping () -> Bool,
        accessibilityPromptRequest: @escaping () -> Bool,
        inputMonitoringAccessCheck: @escaping () -> Bool,
        inputMonitoringAccessRequest: @escaping () -> Bool
    ) {
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.accessibilityPromptRequest = accessibilityPromptRequest
        self.inputMonitoringAccessCheck = inputMonitoringAccessCheck
        self.inputMonitoringAccessRequest = inputMonitoringAccessRequest
    }

    public var isTrusted: Bool {
        accessibilityTrustCheck()
    }

    public var isInputMonitoringEnabled: Bool {
        inputMonitoringAccessCheck()
    }

    public var hotKeyPermissionState: HotKeyPermissionState {
        switch (isTrusted, isInputMonitoringEnabled) {
        case (true, true):
            return .granted
        case (false, true):
            return .accessibilityRequired
        case (true, false):
            return .inputMonitoringRequired
        case (false, false):
            return .accessibilityAndInputMonitoringRequired
        }
    }

    @discardableResult
    public func requestPermissionPrompt() -> Bool {
        accessibilityPromptRequest()
    }

    @discardableResult
    public func requestInputMonitoringPermission() -> Bool {
        inputMonitoringAccessRequest()
    }
}
