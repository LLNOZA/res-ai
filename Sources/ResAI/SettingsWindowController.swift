import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(controller: AppController) {
        let view = SettingsView(controller: controller)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ResponseAi 設定"
        window.setContentSize(NSSize(width: 640, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
