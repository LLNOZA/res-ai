import AppKit
import Carbon.HIToolbox
import ResAICore
import SwiftUI

/// Click-to-record shortcut field, like System Settings > Keyboard Shortcuts.
/// Clicking starts recording; the next key combination is reported through
/// `onCapture`. Modifiers pressed and let go on their own are recorded as a
/// modifier-only chord. Esc (or leaving the window) cancels; the
/// "Esc を登録" button records Esc itself.
struct ShortcutRecorderField: View {
    let displayName: String
    let isRecording: Bool
    let onStart: () -> Void
    let onCapture: (ShortcutTrigger) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            field
            if isRecording {
                Button("Esc を登録") {
                    onCapture(.key(HotKeyShortcut(keyCode: UInt32(kVK_Escape), modifiers: [])))
                }
                .controlSize(.small)
                // Taking focus would end the recording before the click lands.
                .focusable(false)
            }
        }
    }

    private var field: some View {
        Button(action: isRecording ? onCancel : onStart) {
            Text(isRecording ? "キーを押してください…" : displayName)
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(minWidth: 150, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(isRecording ? 0.05 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Esc で中止" : "クリックして新しいショートカットを押す")
        .background {
            if isRecording {
                ShortcutCaptureView(onCapture: onCapture, onCancel: onCancel)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

/// Invisible first responder that receives the raw key events while recording.
private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (ShortcutTrigger) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: ((ShortcutTrigger) -> Void)?
    var onCancel: (() -> Void)?

    private var isFinished = false
    /// Largest modifier set held since all modifiers were last up. Released
    /// without a key in between, it becomes a modifier-only chord (one
    /// modifier alone is fine).
    private var peakModifiers: ShortcutModifiers = []
    private var sawKeySincePeak = false
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        guard let window else {
            finish(with: nil)
            return
        }
        window.makeFirstResponder(self)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(with: nil)
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        finish(with: nil)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let keyCode = UInt32(event.keyCode)
        let modifiers = Self.modifiers(from: event.modifierFlags, includingFunction: false)
        if keyCode == UInt32(kVK_Escape) && modifiers.isEmpty {
            finish(with: nil)
            return
        }
        guard !KeyCodeNames.isModifierKey(keyCode) else { return }
        sawKeySincePeak = true
        finish(with: .key(HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)))
    }

    /// ⌘Q, ⌘W, and the window's default button would otherwise act before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isFinished else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let current = Self.modifiers(from: event.modifierFlags, includingFunction: true)
        if current.isEmpty {
            let chord = peakModifiers
            let sawKey = sawKeySincePeak
            peakModifiers = []
            sawKeySincePeak = false
            if !sawKey, !chord.isEmpty {
                finish(with: .modifierChord(chord))
            }
            return
        }
        peakModifiers.formUnion(current)
    }

    private func finish(with trigger: ShortcutTrigger?) {
        guard !isFinished else { return }
        isFinished = true
        if let trigger {
            onCapture?(trigger)
        } else {
            onCancel?()
        }
    }

    /// The fn flag is dropped for key combinations: macOS sets it on arrows and
    /// F-keys by itself, and fn is only meaningful in modifier-only chords.
    private static func modifiers(from flags: NSEvent.ModifierFlags, includingFunction: Bool) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if includingFunction && flags.contains(.function) { modifiers.insert(.function) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
