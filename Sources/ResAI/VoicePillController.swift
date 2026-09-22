import AppKit
import SwiftUI

@MainActor
final class VoicePillController {
    private let model = VoicePillModel()
    private var panel: NSPanel?
    private var hostingController: NSHostingController<VoicePillView>?
    private var hideTask: Task<Void, Never>?
    private var appearTask: Task<Void, Never>?
    private var hideGeneration: UInt64 = 0
    private var anchoredCenterX: CGFloat?
    private var lastLayoutKey: LayoutKey?

    func show(_ state: VoicePillState, inputFrame: CGRect?, hint: String?) {
        hideTask?.cancel()
        hideTask = nil
        hideGeneration &+= 1

        if case .listening(let level, _) = state {
            model.level = level
        }

        let layoutKey = LayoutKey(kind: state.layoutKind, text: state.displayText, hint: hint)
        let layoutChanged = layoutKey != lastLayoutKey || panel == nil

        if layoutChanged {
            lastLayoutKey = layoutKey
            model.state = state
            model.hint = hint
        }

        let wasVisible = panel?.isVisible == true
        installIfNeeded()

        guard layoutChanged else {
            // Level ticks used to cancel the 16 ms appear task, so the pill stayed at opacity 0.
            if !model.isVisible {
                beginAppear()
            }
            if let duration = state.autoHideDuration {
                scheduleHide(after: duration, generation: hideGeneration)
            }
            return
        }

        let size = Self.size(for: state, hint: hint)
        let panel = ensurePanel(size: size)
        if anchoredCenterX == nil {
            let initial = OverlayPanelGeometry.origin(
                for: size,
                inputFrame: inputFrame,
                gapAboveInput: 8
            )
            anchoredCenterX = initial.x + size.width / 2
        }
        let origin = OverlayPanelGeometry.origin(
            for: size,
            inputFrame: inputFrame,
            gapAboveInput: 8,
            anchoredCenterX: anchoredCenterX
        )
        // Shadow padding hangs below the 40 pt capsule; keep the capsule 8 pt above the field.
        let adjustedOrigin = CGPoint(x: origin.x, y: origin.y - VoicePillView.shadowPadding)
        panel.setContentSize(size)
        panel.setFrameOrigin(adjustedOrigin)
        panel.animationBehavior = .none
        panel.orderFrontRegardless()

        if !(wasVisible && model.isVisible) {
            beginAppear()
        }

        if let duration = state.autoHideDuration {
            scheduleHide(after: duration, generation: hideGeneration)
        }
    }

    func hide(animated: Bool = true) {
        hideTask?.cancel()
        hideTask = nil
        hideGeneration &+= 1
        appearTask?.cancel()
        appearTask = nil

        guard panel?.isVisible == true else {
            resetAnchor()
            return
        }

        if animated, model.isVisible {
            model.isVisible = false
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                self?.orderOut()
            }
        } else {
            orderOut()
        }
    }

    private func beginAppear() {
        if appearTask != nil || model.isVisible {
            return
        }
        appearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.appearTask = nil
            self.model.isVisible = true
        }
    }

    private func scheduleHide(after duration: TimeInterval, generation: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            guard self?.hideGeneration == generation else { return }
            self?.hide(animated: true)
        }
    }

    private func orderOut() {
        panel?.orderOut(nil)
        resetAnchor()
    }

    private func resetAnchor() {
        model.isVisible = false
        anchoredCenterX = nil
        model.level = 0
        lastLayoutKey = nil
    }

    private func installIfNeeded() {
        if hostingController != nil {
            return
        }

        let hosting = NSHostingController(rootView: VoicePillView(model: model))
        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = false
        hostingController = hosting
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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private struct LayoutKey: Equatable {
        var kind: VoicePillLayoutKind
        var text: String
        var hint: String?
    }

    private static func size(for state: VoicePillState, hint: String?) -> NSSize {
        let rawText: String
        if case .listening(_, let text) = state, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawText = "話してください"
        } else {
            rawText = state.displayText
        }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil(
            (rawText as NSString).size(withAttributes: [.font: font]).width
        )

        let leading: CGFloat = 27
        var trailing: CGFloat = 0
        if case .listening = state, let hint, !hint.isEmpty {
            let hintFont = NSFont.systemFont(ofSize: 11)
            trailing = 16 + 2 + ceil((hint as NSString).size(withAttributes: [.font: hintFont]).width)
        } else if case .finishing = state {
            trailing = 16
        }

        let horizontalPadding: CGFloat = 28
        let spacings: CGFloat = 10 + (trailing > 0 ? 10 : 0)
        let width = min(
            VoicePillView.maxWidth,
            max(VoicePillView.minWidth, leading + spacings + textWidth + trailing + horizontalPadding)
        )
        let padding = VoicePillView.shadowPadding * 2
        return NSSize(width: width + padding, height: VoicePillView.height + padding)
    }
}
