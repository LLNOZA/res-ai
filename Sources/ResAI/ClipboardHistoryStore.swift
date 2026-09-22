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
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
            if isEnabled {
                captureCurrentPasteboardText()
            }
        }
    }
    @Published private(set) var items: [ClipboardHistoryItem]

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastChangeCount: Int
    private var persistTask: Task<Void, Never>?
    private var lastCaptureLogAt: Date?
    private var lastLoggedCount: Int?

    private static let maxItems = 50

    init(
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) as? Bool ?? true
        self.items = Self.loadItems(defaults: defaults)
        self.lastChangeCount = pasteboard.changeCount
        self.lastLoggedCount = self.items.count
    }

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
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        persistImmediately()
    }

    func clear() {
        items.removeAll()
        persistImmediately()
        AppLog.write("clipboard history cleared")
    }

    @discardableResult
    func pasteItem(id: UUID, target: FocusedInputTarget?) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else {
            return false
        }

        guard let target else { return false }
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
        guard
            let data = defaults.data(forKey: DefaultsKey.items),
            let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
        else {
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
                await MainActor.run {
                    _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                }
                AXUIElementSetAttributeValue(
                    elementBox.value,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            await InputSynthesizer.shared.sleep(milliseconds: 60)

            clipboardRestoreSelectedTextRange(range, in: elementBox.value)
            AXUIElementSetAttributeValue(
                elementBox.value,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            clipboardRestoreSelectedTextRange(range, in: elementBox.value)
            await InputSynthesizer.shared.sleep(milliseconds: 35)
            try Task.checkCancellation()
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFEqual(focused, elementBox.value) else {
                throw CancellationError()
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
        } catch {
            AppLog.write("clipboard history paste cancelled or target unavailable")
            return false
        }
    }

    private enum DefaultsKey {
        static let isEnabled = "clipboardHistory.isEnabled"
        static let items = "clipboardHistory.items.v1"
    }
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
