import ApplicationServices
import Foundation

public final class AccessibilityPermissionManager {
    public init() {}

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestPermissionPrompt() -> Bool {
        // Use the literal key to avoid Swift 6 treating the imported C global
        // as unsafe shared mutable state.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [
            promptKey: true
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }
}
