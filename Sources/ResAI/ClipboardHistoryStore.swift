import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import ResAICore

struct ClipboardHistoryItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var copiedAt: Date

    init(id: UUID = UUID(), text: String, copiedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
    }

    var previewTitle: String {
        let singleLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard singleLine.count > 72 else {
            return singleLine
        }

        return String(singleLine.prefix(72)) + "..."
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    enum ClearReason: String {
        /// "履歴を消去" in the quick menu or settings.
        case user
        /// The history setting was turned off.
        case disabled
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
            if isEnabled {
                lastChangeCount = pasteboard.changeCount
                captureCurrentPasteboardText()
            } else {
                clear(reason: .disabled)
            }
        }
    }
    @Published private(set) var items: [ClipboardHistoryItem]

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastChangeCount: Int
    private var persistTask: Task<Void, Never>?
    private var lastCaptureLogAt: Date?
    private var lastLoggedCount: Int?

    private static let maxItems = 50

    /// No defaults on purpose: the app passes `AppEnvironment`'s pasteboard and settings,
    /// tests pass their own, and nothing reaches `NSPasteboard.general` by accident.
    init(pasteboard: NSPasteboard, defaults: UserDefaults) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) as? Bool ?? true
        self.items = Self.loadItems(defaults: defaults)
        self.lastChangeCount = pasteboard.changeCount
        self.lastLoggedCount = self.items.count
    }

    var isMonitoring: Bool { timer != nil }

    /// Idempotent: a second call keeps the single running timer and observer.
    func startMonitoring() {
        guard timer == nil else {
            return
        }

        captureCurrentPasteboardText()
        AppLog.write("clipboard history monitor started enabled=\(isEnabled) items=\(items.count)")
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPasteboard()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Timers do not fire during sleep; pick up anything copied right before it at once.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPasteboard()
            }
        }
    }

    /// Stops polling and saves. Never removes items.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        persistImmediately()
    }

    /// The only way items are removed in bulk: an explicit user action or turning history off.
    func clear(reason: ClearReason = .user) {
        let removed = items.count
        items.removeAll()
        persistImmediately()
        AppLog.write("clipboard history cleared reason=\(reason.rawValue) removed=\(removed)")
    }

    @discardableResult
    func pasteItem(id: UUID, target: FocusedInputTarget?) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else {
            AppLog.write("clipboard history paste failed reason=item-missing")
            return false
        }

        guard let target else {
            AppLog.write("clipboard history paste failed reason=no-focused-input")
            return false
        }
        guard await pasteIntoTarget(item.text, target: target) else { return false }
        add(text: item.text, copiedAt: item.copiedAt)

        AppLog.write("clipboard history paste dispatched length=\(item.text.count) app=\(target.appInfo.name)")
        return true
    }

    private func pollPasteboard() {
        let previousCount = items.count
        items.removeAll { !ClipboardHistoryPolicy.isRetained(copiedAt: $0.copiedAt) }
        if previousCount != items.count { schedulePersist() }
        guard isEnabled else {
            lastChangeCount = pasteboard.changeCount
            return
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = changeCount
        captureCurrentPasteboardText()
    }

    private func captureCurrentPasteboardText() {
        guard isEnabled, let text = pasteboard.string(forType: .string) else {
            return
        }
        guard ClipboardHistoryPolicy.shouldStore(text: text, typeNames: (pasteboard.types ?? []).map(\.rawValue)) else { return }
        add(text: text)
    }

    private func add(text rawText: String, copiedAt: Date = Date()) {
        let text = rawText
        guard ClipboardHistoryPolicy.shouldStore(text: text, typeNames: []) else {
            return
        }

        items.removeAll { $0.text == text || !ClipboardHistoryPolicy.isRetained(copiedAt: $0.copiedAt) }
        items.insert(
            ClipboardHistoryItem(text: text, copiedAt: copiedAt),
            at: 0
        )

        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }

        schedulePersist()
        logCaptureIfNeeded(textLength: text.count)
    }

    private func logCaptureIfNeeded(textLength: Int) {
        let countChanged = items.count != lastLoggedCount
        let elapsed = Date().timeIntervalSince(lastCaptureLogAt ?? .distantPast)
        guard countChanged || elapsed >= 10 else {
            return
        }
        lastLoggedCount = items.count
        lastCaptureLogAt = Date()
        AppLog.write("clipboard history captured length=\(textLength) items=\(items.count)")
    }

    private func persistImmediately() {
        persistTask?.cancel()
        persistTask = nil
        let snapshot = items
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: DefaultsKey.items)
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = items
        persistTask = Task { [defaults] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .utility) {
                try? JSONEncoder().encode(snapshot)
            }.value
            guard !Task.isCancelled, let data else { return }
            defaults.set(data, forKey: DefaultsKey.items)
        }
    }

    private static func loadItems(defaults: UserDefaults) -> [ClipboardHistoryItem] {
        guard let data = defaults.data(forKey: DefaultsKey.items) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else {
            // The next save would overwrite the unreadable copy with an empty list.
            // Keep it aside so the loss is visible and recoverable.
            defaults.set(data, forKey: DefaultsKey.unreadableItems)
            AppLog.write("clipboard history unreadable bytes=\(data.count); kept as backup")
            return []
        }

        return Array(decoded.filter {
            ClipboardHistoryPolicy.isRetained(copiedAt: $0.copiedAt)
                && ClipboardHistoryPolicy.shouldStore(text: $0.text, typeNames: [])
        }.prefix(maxItems))
    }

    private func pasteIntoTarget(_ text: String, target: FocusedInputTarget) async -> Bool {
        struct ElementBox: @unchecked Sendable {
            let value: AXUIElement
        }

        let elementBox = ElementBox(value: target.inputElement)
        let range = target.selectedTextRange
        let pid = target.appInfo.processIdentifier
        do {
          try await InputSynthesizer.shared.run { [weak self] in
            try Task.checkCancellation()
            if let pid {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, 0.15)
                AXUIElementPerformAction(appElement, kAXRaiseAction as CFString)
                let activation = await MainActor.run { () -> Bool? in
                    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                }
                guard let activated = activation else {
                    throw ClipboardPasteFailure(reason: "target-app-gone")
                }
                if !activated {
                    // macOS 14+ cooperative activation may refuse; the focus check below decides.
                    await MainActor.run { AppLog.write("clipboard history paste: target activation refused") }
                }
                AXUIElementSetAttributeValue(
                    elementBox.value,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            await InputSynthesizer.shared.sleep(milliseconds: 60)

            clipboardRestoreSelectedTextRange(range, in: elementBox.value)
            let focusResult = AXUIElementSetAttributeValue(
                elementBox.value,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            clipboardRestoreSelectedTextRange(range, in: elementBox.value)
            await InputSynthesizer.shared.sleep(milliseconds: 35)
            try Task.checkCancellation()
            var focused: CFTypeRef?
            let readResult = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
            guard readResult == .success, let focused else {
                throw ClipboardPasteFailure(reason: "focus-unreadable axError=\(readResult.rawValue)")
            }
            guard CFEqual(focused, elementBox.value) else {
                throw ClipboardPasteFailure(reason: "focus-moved setFocusAXError=\(focusResult.rawValue)")
            }
            // Keep clipboard publication in the same serialized operation as Cmd+V.
            guard let self else { throw CancellationError() }
            let previous = await MainActor.run { () -> ([[String: Data]], Int) in
                let snapshot = self.pasteboard.pasteboardItems?.map { item in
                    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                        item.data(forType: type).map { (type.rawValue, $0) }
                    })
                } ?? []
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                self.lastChangeCount = self.pasteboard.changeCount
                return (snapshot, self.pasteboard.changeCount)
            }
            do {
                try Task.checkCancellation()
                await InputSynthesizer.shared.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_V))
                try Task.checkCancellation()
            } catch {
                await MainActor.run {
                    guard self.pasteboard.changeCount == previous.1 else { return }
                    self.pasteboard.clearContents()
                    let items = previous.0.map { values in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                        return item
                    }
                    if !items.isEmpty { self.pasteboard.writeObjects(items) }
                    self.lastChangeCount = self.pasteboard.changeCount
                }
                throw error
            }
          }
          return true
        } catch let failure as ClipboardPasteFailure {
            AppLog.write("clipboard history paste failed reason=\(failure.reason) app=\(target.appInfo.name)")
            return false
        } catch {
            AppLog.write("clipboard history paste failed reason=cancelled app=\(target.appInfo.name)")
            return false
        }
    }

    private enum DefaultsKey {
        static let isEnabled = "clipboardHistory.isEnabled"
        static let items = "clipboardHistory.items.v1"
        static let unreadableItems = "clipboardHistory.items.v1.unreadable"
    }
}

/// Why a quick-menu paste was abandoned. The reason goes to the log; the text never does.
private struct ClipboardPasteFailure: Error {
    let reason: String
}

private func clipboardRestoreSelectedTextRange(_ range: CFRange?, in element: AXUIElement) {
    guard var mutableRange = range else {
        return
    }
    guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
        return
    }
    AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        rangeValue
    )
}
