import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class AccessibilityReader {
    private let contextFilter: ContextTextFilter
    private let screenTextReader: ScreenTextReader
    private let isScreenTextEnabled: () -> Bool
    private let maxTraversalDepth: Int
    private let maxCollectedElements: Int
    private let maxTraversalMilliseconds: UInt64

    public init(
        contextFilter: ContextTextFilter = ContextTextFilter(),
        screenTextReader: ScreenTextReader = ScreenTextReader(),
        isScreenTextEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "privacy.screenTextContextEnabled") as? Bool ?? true
        },
        maxTraversalDepth: Int = 9,
        maxCollectedElements: Int = 500,
        maxTraversalMilliseconds: UInt64 = 750
    ) {
        self.contextFilter = contextFilter
        self.screenTextReader = screenTextReader
        self.isScreenTextEnabled = isScreenTextEnabled
        self.maxTraversalDepth = maxTraversalDepth
        self.maxCollectedElements = maxCollectedElements
        self.maxTraversalMilliseconds = max(1, maxTraversalMilliseconds)
    }

    public func captureFocusedComposition() async throws -> FocusedComposition {
        let systemWide = AXHelpers.systemWide()
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedError == .success, let focusedElement = focusedValue else {
            throw AXReadError.focusedElementUnavailable(focusedError)
        }

        guard let inputElement = AXHelpers.uiElement(from: focusedElement) else {
            throw AXReadError.focusedElementUnavailable(focusedError)
        }
        AXHelpers.applyMessagingTimeout(inputElement)
        // Read the complete value first. `readText` intentionally prefers AXSelectedText for
        // the AI prompt, but a guarded write must retain this full snapshot for comparison and
        // for selection-preserving edit planning.
        let originalFieldValue = AXHelpers.copyString(kAXValueAttribute as CFString, from: inputElement)
        let inputFrame = AXHelpers.frame(of: inputElement)
        let selectedTextRange = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: inputElement)
        let draftText: String
        if let originalFieldValue, let selectedTextRange {
            if selectedTextRange.length == 0 {
                draftText = originalFieldValue
            } else {
                guard
                    let selectedFromValue = Self.utf16Substring(originalFieldValue, range: selectedTextRange),
                    let selectedText = AXHelpers.copyString(kAXSelectedTextAttribute as CFString, from: inputElement),
                    selectedFromValue == selectedText
                else {
                    throw AXReadError.selectionSnapshotMismatch
                }
                draftText = selectedText
            }
        } else {
            draftText = Self.readText(from: inputElement) ?? ""
        }

        var pid: pid_t = 0
        AXUIElementGetPid(inputElement, &pid)
        let appInfo = appInfo(for: pid)
        let appElement = AXHelpers.application(pid: pid)
        let focusedWindow = AXHelpers.copyUIElement(kAXFocusedWindowAttribute as CFString, from: appElement)

        let root = focusedWindow ?? appElement
        let rootBox = UncheckedAXElement(root)
        let maxDepth = maxTraversalDepth
        let maxElements = maxCollectedElements
        let maxMilliseconds = maxTraversalMilliseconds
        let allLines = await withCheckedContinuation { (continuation: CheckedContinuation<[ContextLine], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                        returning: Self.collectContextLines(
                            root: rootBox.value,
                            maxTraversalDepth: maxDepth,
                            maxCollectedElements: maxElements,
                            maxTraversalMilliseconds: maxMilliseconds
                    )
                )
            }
        }
        let appTunedFilter = contextFilter.tuned(for: appInfo)
        let accessibilityContextLines = appTunedFilter.filter(
            lines: allLines,
            inputFrame: inputFrame,
            draft: draftText
        )
        // OCR is a fallback for browser surfaces that did not yield enough AX context. This
        // avoids mixing a second, potentially unrelated window into a healthy AX capture.
        let shouldUseScreenText = shouldUseScreenText(for: appInfo)
            && accessibilityContextLines.count < max(2, appTunedFilter.maxLines / 2)
        let screenTextAuthorized = shouldUseScreenText ? ScreenTextReader.hasScreenCaptureAccess() : false
        // Screen capture + Vision OCR is the only multi-second step here and it is NOT an
        // Accessibility call, so run it off the main actor. The main actor stays responsive
        // (menu bar, HUD, other hotkeys) while OCR runs, instead of freezing for up to ~2.5s.
        var rawScreenLines: [ContextLine]
        if shouldUseScreenText {
            let screenReader = screenTextReader
            let ocrFrame = inputFrame
            let ocrMaxLines = appTunedFilter.maxLines + 8
            let frontmostPIDAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
            rawScreenLines = await withCheckedContinuation { (continuation: CheckedContinuation<[ContextLine], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: screenReader.captureContextLines(above: ocrFrame, maxLines: ocrMaxLines)
                    )
                }
            }
            // ScreenCaptureKit captures a display, not an AX window. If focus/frontmost app
            // changed while OCR ran, discard the result rather than attaching another window's
            // conversation to this composition.
            if !Self.isSameFocusedTarget(inputElement, pid: appInfo.processIdentifier)
                || NSWorkspace.shared.frontmostApplication?.processIdentifier != frontmostPIDAtStart {
                rawScreenLines = []
            }
        } else {
            rawScreenLines = []
        }
        let screenContextLines = shouldUseScreenText
            ? appTunedFilter.filter(
                lines: rawScreenLines,
                inputFrame: inputFrame,
                draft: draftText
            )
            : []
        let contextLines = mergedContextLines(
            primary: screenContextLines,
            secondary: accessibilityContextLines,
            limit: appTunedFilter.maxLines
        )
        let diagnostics = ContextCaptureDiagnostics(
            accessibilityLineCount: accessibilityContextLines.count,
            screenTextLineCount: screenContextLines.count,
            screenTextAttempted: shouldUseScreenText,
            screenTextAuthorized: screenTextAuthorized
        )

        return FocusedComposition(
            appInfo: appInfo,
            inputElement: inputElement,
            inputFrame: inputFrame,
            selectedTextRange: selectedTextRange,
            originalFieldValue: originalFieldValue,
            draftText: draftText,
            contextLines: contextLines,
            contextDiagnostics: diagnostics
        )
    }

    public func captureFocusedInputFrame() throws -> CGRect? {
        try captureFocusedInputTarget().inputFrame
    }

    public func captureFocusedInputTarget() throws -> FocusedInputTarget {
        let systemWide = AXHelpers.systemWide()
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedError == .success, let focusedElement = focusedValue else {
            throw AXReadError.focusedElementUnavailable(focusedError)
        }

        guard let inputElement = AXHelpers.uiElement(from: focusedElement) else {
            throw AXReadError.focusedElementUnavailable(focusedError)
        }
        AXHelpers.applyMessagingTimeout(inputElement)
        let inputFrame = AXHelpers.frame(of: inputElement)
        let selectedTextRange = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: inputElement)
        var pid: pid_t = 0
        AXUIElementGetPid(inputElement, &pid)

        return FocusedInputTarget(
            appInfo: appInfo(for: pid),
            inputElement: inputElement,
            inputFrame: inputFrame,
            selectedTextRange: selectedTextRange
        )
    }

    private func appInfo(for pid: pid_t) -> AppInfo {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return AppInfo(name: "Unknown App", bundleIdentifier: nil, processIdentifier: pid)
        }

        return AppInfo(
            name: app.localizedName ?? "Unknown App",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: pid
        )
    }

    nonisolated private static func collectContextLines(
        root: AXUIElement,
        maxTraversalDepth: Int,
        maxCollectedElements: Int,
        maxTraversalMilliseconds: UInt64
    ) -> [ContextLine] {
        var lines: [ContextLine] = []
        var visited = Set<UInt>()
        let deadline = DispatchTime.now().uptimeNanoseconds + maxTraversalMilliseconds * 1_000_000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxTraversalDepth else {
                return
            }
            guard lines.count < maxCollectedElements else {
                return
            }
            guard visited.count < maxCollectedElements else {
                return
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return
            }

            let identity = CFHash(element)
            guard visited.insert(identity).inserted else {
                return
            }

            if let line = contextLine(from: element) {
                lines.append(line)
            }

            for child in AXHelpers.copyChildren(from: element) {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return lines
    }

    nonisolated private static func contextLine(from element: AXUIElement) -> ContextLine? {
        let role = AXHelpers.copyString(kAXRoleAttribute as CFString, from: element) ?? ""
        let textAttributes = [
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString
        ]

        for attribute in textAttributes {
            guard let rawText = AXHelpers.copyString(attribute, from: element) else {
                continue
            }

            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            if role == kAXButtonRole as String, text.count <= 24 {
                continue
            }

            return ContextLine(text: text, frame: AXHelpers.frame(of: element))
        }

        return nil
    }

    nonisolated private static func readText(from element: AXUIElement) -> String? {
        if let selectedText = AXHelpers.copyString(kAXSelectedTextAttribute as CFString, from: element),
           !selectedText.isEmpty {
            return selectedText
        }

        if let value = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) {
            return value
        }

        return AXHelpers.copyString(kAXTitleAttribute as CFString, from: element)
    }

    nonisolated private static func utf16Substring(_ value: String, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else {
            return nil
        }
        let utf16 = value.utf16
        guard
            let startOffset = Int(exactly: range.location),
            let rangeLength = Int(exactly: range.length)
        else {
            return nil
        }
        let (endOffset, overflow) = startOffset.addingReportingOverflow(rangeLength)
        guard !overflow, startOffset <= endOffset, endOffset <= utf16.count else {
            return nil
        }
        let startUTF16 = utf16.index(utf16.startIndex, offsetBy: startOffset)
        let endUTF16 = utf16.index(utf16.startIndex, offsetBy: endOffset)
        guard
            let start = String.Index(startUTF16, within: value),
            let end = String.Index(endUTF16, within: value)
        else {
            return nil
        }
        return String(value[start..<end])
    }

    private static func isSameFocusedTarget(_ target: AXUIElement, pid: pid_t?) -> Bool {
        guard let pid else {
            return false
        }
        let appElement = AXHelpers.application(pid: pid)
        guard let focused = AXHelpers.copyUIElement(kAXFocusedUIElementAttribute as CFString, from: appElement) else {
            return false
        }
        return CFEqual(focused, target)
    }

    private func shouldUseScreenText(for appInfo: AppInfo) -> Bool {
        guard isScreenTextEnabled() else {
            return false
        }

        let bundle = appInfo.bundleIdentifier?.lowercased() ?? ""
        let name = appInfo.name.lowercased()
        let browserSignals = [
            "chrome",
            "safari",
            "arc",
            "edgemac",
            "microsoft.edge",
            "firefox",
            "thebrowser"
        ]

        return browserSignals.contains { signal in
            bundle.contains(signal) || name.contains(signal)
        }
    }

    private func mergedContextLines(
        primary: [ContextLine],
        secondary: [ContextLine],
        limit: Int
    ) -> [ContextLine] {
        var seen = Set<String>()
        var merged: [ContextLine] = []

        for line in primary + secondary {
            let key = line.text.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }
            merged.append(line)
            if merged.count >= limit {
                break
            }
        }

        return merged
    }
}
