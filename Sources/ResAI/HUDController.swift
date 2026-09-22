import AppKit
import SwiftUI

@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<HUDView>?
    private var hideTask: Task<Void, Never>?

    func show(_ message: HUDMessage) {
        hideTask?.cancel()

        let view = HUDView(message: message)
        if let hostingController {
            hostingController.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            hosting.view.wantsLayer = true
            hosting.view.layer?.cornerRadius = 8
            hosting.view.layer?.masksToBounds = true
            hostingController = hosting
        }

        let size = size(for: message)
        let panel = ensurePanel(size: size)
        panel.setContentSize(size)
        panel.setFrameOrigin(
            OverlayPanelGeometry.origin(for: size, inputFrame: message.inputFrame, gapAboveInput: 10)
        )
        panel.orderFrontRegardless()

        if let duration = message.duration {
            hideTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        self.panel = panel
        return panel
    }

    private func size(for message: HUDMessage) -> NSSize {
        if message.preview?.isEmpty == false {
            return NSSize(width: 420, height: 132)
        }
        return NSSize(width: 320, height: 76)
    }
}
