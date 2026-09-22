import Foundation

public enum AppAutomationPolicy {
    public static func prefersClipboardPaste(for appInfo: AppInfo) -> Bool {
        let bundle = appInfo.bundleIdentifier?.lowercased() ?? ""
        let name = appInfo.name.lowercased()
        let signals = [
            "arc",
            "chrome",
            "discord",
            "edgemac",
            "electron",
            "facebook",
            "firefox",
            "line",
            "messenger",
            "microsoft.edge",
            "msteams",
            "safari",
            "slack",
            "teams",
            "thebrowser",
            "tinyspeck",
            "whatsapp"
        ]

        return signals.contains { signal in
            bundle.contains(signal) || name.contains(signal)
        }
    }
}
