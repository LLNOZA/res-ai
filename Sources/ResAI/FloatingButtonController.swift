import AppKit
import SwiftUI

@MainActor
final class FloatingButtonController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<FloatingButtonView>?
    private let onRewrite: () -> Void
    private let onRestore: () -> Void
    private let onSettings: () -> Void

    init(onRewrite: @escaping () -> Void, onRestore: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onRewrite = onRewrite
        self.onRestore = onRestore
        self.onSettings = onSettings
    }

    func show() {
        let size = NSSize(width: 54, height: 54)
        let view = FloatingButtonView(
            onRewrite: onRewrite,
            onRestore: onRestore,
            onSettings: onSettings
        )

        if let hostingController {
            hostingController.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            hosting.view.wantsLayer = true
            hostingController = hosting
        }

        let panel = ensurePanel(size: size)
        panel.setContentSize(size)
        panel.setFrameOrigin(defaultOrigin(size: size))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        self.panel = panel
        return panel
    }

    private func defaultOrigin(size: NSSize) -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 120, y: 120)
        }

        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.maxX - size.width - 18,
            y: visible.maxY - size.height - 34
        )
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
