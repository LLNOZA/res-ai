import AppKit
import ApplicationServices
import Carbon
import Foundation

public enum TextReplacementError: LocalizedError {
    case accessibilitySetFailed(AXError)
    case pasteboardFallbackFailed
    case guardedTargetChanged
    case guardedTargetUnavailable

    public var errorDescription: String? {
        switch self {
        case let .accessibilitySetFailed(error):
            "Accessibility text replacement failed (\(error.rawValue))."
        case .pasteboardFallbackFailed:
            "Clipboard paste fallback failed."
        case .guardedTargetChanged:
            "The input changed while the replacement was waiting; nothing was overwritten."
        case .guardedTargetUnavailable:
            "The original input target is no longer focused; nothing was overwritten."
        }
    }
}

public enum TextReplacementMethod: String, Sendable {
    case accessibilityValue
    case accessibilitySelectedText
    case clipboardPaste
}

/// Pure ownership rules used by the pasteboard handoff coordinator. A change-count mismatch
/// always means another process/user owns the board; stale restore snapshots must be discarded.
public enum ClipboardOwnershipPolicy {
    public static func canAdoptPending(
        pendingWriteChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        pendingWriteChangeCount == currentChangeCount
    }

    public static func shouldRestore(
        expectedWriteChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        expectedWriteChangeCount == currentChangeCount
    }
}

public struct TextReplacementResult: Equatable, Sendable {
    public var method: TextReplacementMethod
    public var verified: Bool

    public init(method: TextReplacementMethod, verified: Bool) {
        self.method = method
        self.verified = verified
    }
}

/// AXUIElement is a CF handle; records cross the input-synthesizer task chain and MainActor
/// without concurrent mutation of `element`.
public struct TextInsertionRecord: Equatable, @unchecked Sendable {
    public var element: AXUIElement
    public var inputFrame: CGRect?
    public var insertedText: String
    /// UTF-16 range of the inserted text inside the field's AXValue, if it could be determined.
    public var insertedRange: CFRange?
    /// Snapshot of the whole field value right after insertion (nil if unreadable).
    public var valueAfterInsertion: String?
    public var method: TextReplacementMethod
    public var verified: Bool

    public init(
        element: AXUIElement,
        inputFrame: CGRect?,
        insertedText: String,
        insertedRange: CFRange?,
        valueAfterInsertion: String?,
        method: TextReplacementMethod,
        verified: Bool
    ) {
        self.element = element
        self.inputFrame = inputFrame
        self.insertedText = insertedText
        self.insertedRange = insertedRange
        self.valueAfterInsertion = valueAfterInsertion
        self.method = method
        self.verified = verified
    }

    public static func == (lhs: TextInsertionRecord, rhs: TextInsertionRecord) -> Bool {
        CFEqual(lhs.element, rhs.element)
            && lhs.inputFrame == rhs.inputFrame
            && lhs.insertedText == rhs.insertedText
            && optionalCFRangesEqual(lhs.insertedRange, rhs.insertedRange)
            && lhs.valueAfterInsertion == rhs.valueAfterInsertion
            && lhs.method == rhs.method
            && lhs.verified == rhs.verified
    }
}

public final class TextReplacer: @unchecked Sendable {
    private let synthesizer: InputSynthesizer

    public init(synthesizer: InputSynthesizer = .shared) {
        self.synthesizer = synthesizer
    }

    @MainActor
    public func replaceFocusedText(
        with text: String,
        in element: AXUIElement,
        inputFrame: CGRect? = nil,
        selectedTextRange: CFRange? = nil,
        preferClipboardPaste: Bool = false,
        expectedOriginalText: String? = nil,
        requireFocusedTarget: Bool = false
    ) async throws -> TextReplacementResult {
        let elementBox = AXElementBox(element)
        return try await synthesizer.run { [synthesizer] in
            try await Self.replaceFocusedTextOnSynth(
                text: text,
                element: elementBox.value,
                inputFrame: inputFrame,
                selectedTextRange: selectedTextRange,
                preferClipboardPaste: preferClipboardPaste,
                expectedOriginalText: expectedOriginalText,
                requireFocusedTarget: requireFocusedTarget,
                synthesizer: synthesizer
            )
        }
    }

    /// UTF-16 prefix of the field value up to the current selection start. Nil if value or range cannot be read.
    @MainActor
    public func textBeforeCaret(in element: AXUIElement) -> String? {
        guard let value = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) else {
            return nil
        }
        guard let range = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: element) else {
            return nil
        }
        return Self.utf16Substring(value, range: CFRange(location: 0, length: range.location))
    }

    /// Inserts `text` at the current caret / replaces the current selection, WITHOUT touching the rest of the field.
    /// When `assumeFocused` is true and the element's app is already frontmost, skip activate + click
    /// and use short waits so the caret is not moved. Rewrite / form-fill keep the default `false`.
    @MainActor
    public func insertAtCaret(
        _ text: String,
        in element: AXUIElement,
        inputFrame: CGRect?,
        preferClipboardPaste: Bool,
        assumeFocused: Bool = false
    ) async throws -> TextInsertionRecord {
        let elementBox = AXElementBox(element)
        return try await synthesizer.run { [synthesizer] in
            try await Self.insertAtCaretOnSynth(
                text: text,
                element: elementBox.value,
                inputFrame: inputFrame,
                preferClipboardPaste: preferClipboardPaste,
                assumeFocused: assumeFocused,
                synthesizer: synthesizer
            )
        }
    }

    /// Replaces only the previously inserted text with `newText`. Returns nil if it is not safe (field changed,
    /// range unknown and cannot be re-derived) — in that case NOTHING is modified.
    @MainActor
    public func replaceInsertedText(_ record: TextInsertionRecord, with newText: String) async -> TextInsertionRecord? {
        try? await synthesizer.run { [synthesizer] in
            await Self.replaceInsertedTextOnSynth(record, with: newText, synthesizer: synthesizer)
        }
    }

    /// Replaces the previously inserted text by selecting backwards with ⇧← then pasting.
    /// Returns nil without synthesizing keys when any precondition fails (including user typing).
    @MainActor
    public func replaceInsertedTextViaKeyboard(
        _ record: TextInsertionRecord,
        with newText: String,
        `guard` keyboardGuard: KeyboardSwapGuard
    ) async -> TextInsertionRecord? {
        try? await synthesizer.run { [synthesizer] in
            await Self.replaceInsertedTextViaKeyboardOnSynth(
                record,
                with: newText,
                guard: keyboardGuard,
                synthesizer: synthesizer
            )
        }
    }

    @MainActor
    public func keyboardSwapSkipReason(
        _ record: TextInsertionRecord,
        `guard` keyboardGuard: KeyboardSwapGuard
    ) -> KeyboardSwapSkipReason? {
        if keyboardGuard.userTypedSinceInsertion {
            return .userTypedOrClicked
        }
        if KeyboardSwapPlan.shiftLeftCount(for: record.insertedText) == nil {
            return .insertedTextTooLong
        }
        if !Self.isOwningApplicationFrontmost(for: record.element) {
            return .appNotFrontmost
        }
        if !Self.focusedElementAllowsKeyboardSwap(record.element) {
            return .focusMismatch
        }
        return nil
    }

    private static func replaceFocusedTextOnSynth(
        text: String,
        element: AXUIElement,
        inputFrame: CGRect?,
        selectedTextRange: CFRange?,
        preferClipboardPaste: Bool,
        expectedOriginalText: String?,
        requireFocusedTarget: Bool,
        synthesizer: InputSynthesizer
    ) async throws -> TextReplacementResult {
        let guarded = expectedOriginalText != nil || requireFocusedTarget
        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: requireFocusedTarget
        ) else {
            throw expectedOriginalText == nil
                ? TextReplacementError.guardedTargetUnavailable
                : TextReplacementError.guardedTargetChanged
        }

        if guarded && !requireFocusedTarget {
            guard prepareGuardedTarget(element, expectedOriginalText: expectedOriginalText) else {
                throw TextReplacementError.guardedTargetUnavailable
            }
        }

        if !preferClipboardPaste {
            guard !guarded || validateGuardedTarget(
                element,
                expectedOriginalText: expectedOriginalText,
                requireFocusedTarget: guarded
            ) else {
                throw TextReplacementError.guardedTargetChanged
            }
            let setError = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                text as CFTypeRef
            )

            if setError == .success {
                if await waitUntilInserted(
                    text,
                    in: element,
                    strictTarget: guarded,
                    synthesizer: synthesizer
                ) {
                    return TextReplacementResult(method: .accessibilityValue, verified: true)
                }
            }
        }

        guard let result = await pasteIntoFocusedElement(
            text,
            element: element,
            inputFrame: inputFrame,
            selectedTextRange: selectedTextRange,
            allowAccessibilitySelectedText: !preferClipboardPaste,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: requireFocusedTarget,
            synthesizer: synthesizer
        ) else {
            throw TextReplacementError.pasteboardFallbackFailed
        }
        return result
    }

    private static func insertAtCaretOnSynth(
        text: String,
        element: AXUIElement,
        inputFrame: CGRect?,
        preferClipboardPaste: Bool,
        assumeFocused: Bool,
        synthesizer: InputSynthesizer
    ) async throws -> TextInsertionRecord {
        if !preferClipboardPaste,
           let record = await insertViaSelectedText(text, in: element, inputFrame: inputFrame, synthesizer: synthesizer) {
            return record
        }

        guard let record = await pasteAtCaret(
            text,
            in: element,
            inputFrame: inputFrame,
            assumeFocused: assumeFocused,
            synthesizer: synthesizer
        ) else {
            throw TextReplacementError.pasteboardFallbackFailed
        }
        return record
    }

    private static func replaceInsertedTextOnSynth(
        _ record: TextInsertionRecord,
        with newText: String,
        synthesizer: InputSynthesizer
    ) async -> TextInsertionRecord? {
        guard !Task.isCancelled, focusedElementMatches(record.element) else {
            return nil
        }
        guard let currentValue = AXHelpers.copyString(kAXValueAttribute as CFString, from: record.element) else {
            return nil
        }

        guard let range = rangeForReplacingInsertion(
            insertedText: record.insertedText,
            insertedRange: record.insertedRange,
            valueAfterInsertion: record.valueAfterInsertion,
            currentValue: currentValue
        ) else {
            return nil
        }

        guard AXHelpers.setRange(
            range,
            attribute: kAXSelectedTextRangeAttribute as CFString,
            on: record.element
        ) else {
            return nil
        }
        guard !Task.isCancelled, focusedElementMatches(record.element) else {
            return nil
        }

        let expectedRange = CFRange(location: range.location, length: newText.utf16.count)

        let setError = AXUIElementSetAttributeValue(
            record.element,
            kAXSelectedTextAttribute as CFString,
            newText as CFTypeRef
        )

        if setError == .success {
            _ = await waitUntilInserted(
                newText,
                in: record.element,
                strictTarget: true,
                synthesizer: synthesizer
            )
            return verifiedReplacementRecord(
                from: record,
                newText: newText,
                expectedRange: expectedRange,
                method: .accessibilitySelectedText
            )
        }

        return await pasteOverCurrentSelection(
            newText,
            record: record,
            expectedRange: expectedRange,
            synthesizer: synthesizer
        )
    }

    private static func replaceInsertedTextViaKeyboardOnSynth(
        _ record: TextInsertionRecord,
        with newText: String,
        `guard` keyboardGuard: KeyboardSwapGuard,
        synthesizer: InputSynthesizer
    ) async -> TextInsertionRecord? {
        if keyboardSwapSkipReasonSync(record, guard: keyboardGuard) != nil {
            return nil
        }

        guard let shiftLeftCount = KeyboardSwapPlan.shiftLeftCount(for: record.insertedText) else {
            return nil
        }

        guard let beforeValue = AXHelpers.copyString(kAXValueAttribute as CFString, from: record.element),
              let insertedRange = rangeForReplacingInsertion(
                  insertedText: record.insertedText,
                  insertedRange: record.insertedRange,
                  valueAfterInsertion: record.valueAfterInsertion,
                  currentValue: beforeValue
              ),
              let expectedValue = CapturedTextEditPlan.valueByReplacingSelection(
                  originalValue: beforeValue,
                  selectedRange: insertedRange,
                  replacementText: newText
              ) else {
            // A keyboard swap is only safe when the current readable value identifies exactly
            // which insertion is being replaced. Do not guess from a duplicate occurrence.
            return nil
        }

        keyboardGuard.pause()
        defer { keyboardGuard.resume() }

        if keyboardGuard.userTypedSinceInsertion {
            return nil
        }

        await synthesizer.sendShiftLeftArrow(times: shiftLeftCount)

        guard !Task.isCancelled,
              !keyboardGuard.userTypedSinceInsertion,
              focusedElementMatches(record.element),
              AXHelpers.copyString(kAXValueAttribute as CFString, from: record.element) == beforeValue else {
            return nil
        }

        let snapshot = await snapshotPasteboard()
        guard await writePasteboardString(newText) else {
            schedulePasteboardRestore(snapshot)
            return nil
        }

        guard !Task.isCancelled,
              !keyboardGuard.userTypedSinceInsertion,
              focusedElementMatches(record.element),
              AXHelpers.copyString(kAXValueAttribute as CFString, from: record.element) == beforeValue else {
            schedulePasteboardRestore(snapshot)
            return nil
        }
        await synthesizer.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_V))
        let verified = await waitUntilValue(
            expectedValue,
            in: record.element,
            strictTarget: true,
            synthesizer: synthesizer
        )
        schedulePasteboardRestore(snapshot)

        guard !Task.isCancelled,
              !keyboardGuard.userTypedSinceInsertion,
              verified else {
            return nil
        }

        return TextInsertionRecord(
            element: record.element,
            inputFrame: record.inputFrame,
            insertedText: newText,
            insertedRange: CFRange(location: insertedRange.location, length: newText.utf16.count),
            valueAfterInsertion: expectedValue,
            method: .clipboardPaste,
            verified: true
        )
    }

    private static func keyboardSwapSkipReasonSync(
        _ record: TextInsertionRecord,
        `guard` keyboardGuard: KeyboardSwapGuard
    ) -> KeyboardSwapSkipReason? {
        if keyboardGuard.userTypedSinceInsertion {
            return .userTypedOrClicked
        }
        if KeyboardSwapPlan.shiftLeftCount(for: record.insertedText) == nil {
            return .insertedTextTooLong
        }
        if !isOwningApplicationFrontmost(for: record.element) {
            return .appNotFrontmost
        }
        if !focusedElementAllowsKeyboardSwap(record.element) {
            return .focusMismatch
        }
        return nil
    }

    private static func insertViaSelectedText(
        _ text: String,
        in element: AXUIElement,
        inputFrame: CGRect?,
        synthesizer: InputSynthesizer
    ) async -> TextInsertionRecord? {
        guard !Task.isCancelled, focusedElementMatches(element) else {
            return nil
        }
        guard let valueBefore = AXHelpers.copyString(kAXValueAttribute as CFString, from: element),
              let caretBefore = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: element),
              let expectedValue = CapturedTextEditPlan.valueByReplacingSelection(
                  originalValue: valueBefore,
                  selectedRange: caretBefore,
                  replacementText: text
              ) else {
            // Without a complete pre-write snapshot, use the clipboard path rather than
            // mutating a field whose insertion result cannot be proved exactly.
            return nil
        }
        guard !Task.isCancelled,
              focusedElementMatches(element),
              AXHelpers.copyString(kAXValueAttribute as CFString, from: element) == valueBefore,
              let currentCaret = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: element),
              currentCaret.location == caretBefore.location,
              currentCaret.length == caretBefore.length else {
            return nil
        }
        let setError = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard setError == .success else {
            return nil
        }

        guard !Task.isCancelled else {
            // The AX write already happened. Stop here rather than allowing the caller to
            // fall through to clipboard paste, which could duplicate the insertion.
            return TextInsertionRecord(
                element: element,
                inputFrame: inputFrame,
                insertedText: text,
                insertedRange: nil,
                valueAfterInsertion: AXHelpers.copyString(kAXValueAttribute as CFString, from: element),
                method: .accessibilitySelectedText,
                verified: false
            )
        }

        _ = await waitUntilValue(
            expectedValue,
            in: element,
            strictTarget: true,
            synthesizer: synthesizer
        )

        let value = AXHelpers.copyString(kAXValueAttribute as CFString, from: element)
        if let value, value == valueBefore {
            if expectedValue != valueBefore {
                // A readable changed-to-unchanged value proves the AX write was a no-op. Return
                // nil so the caller can use its clipboard fallback without duplicating text.
                return nil
            }
            // Replacing a selection with identical text leaves the full value unchanged, but
            // it is still a valid insertion record. Treating it as a no-op would fall through
            // to clipboard paste and append a duplicate.
            return TextInsertionRecord(
                element: element,
                inputFrame: inputFrame,
                insertedText: text,
                insertedRange: CFRange(location: caretBefore.location, length: text.utf16.count),
                valueAfterInsertion: value,
                method: .accessibilitySelectedText,
                verified: true
            )
        }
        guard let value else {
            return TextInsertionRecord(
                element: element,
                inputFrame: inputFrame,
                insertedText: text,
                insertedRange: nil,
                valueAfterInsertion: value,
                method: .accessibilitySelectedText,
                verified: false
            )
        }

        guard value == expectedValue else {
            // The field changed, but not to the exact expected result. Never guess an
            // occurrence/range: cleanup must not replace unrelated existing text.
            return TextInsertionRecord(
                element: element,
                inputFrame: inputFrame,
                insertedText: text,
                insertedRange: nil,
                valueAfterInsertion: value,
                method: .accessibilitySelectedText,
                verified: false
            )
        }

        return TextInsertionRecord(
            element: element,
            inputFrame: inputFrame,
            insertedText: text,
            insertedRange: CFRange(location: caretBefore.location, length: text.utf16.count),
            valueAfterInsertion: value,
            method: .accessibilitySelectedText,
            verified: true
        )
    }

    private static func pasteAtCaret(
        _ text: String,
        in element: AXUIElement,
        inputFrame: CGRect?,
        assumeFocused: Bool,
        synthesizer: InputSynthesizer
    ) async -> TextInsertionRecord? {
        let skipActivateAndClick = assumeFocused

        if assumeFocused {
            // Voice insertion must never force a newly selected same-app field to focus. The
            // caller captured this element while it was focused; if focus moved, abort instead.
            guard !Task.isCancelled, focusedElementMatches(element) else {
                return nil
            }
        }

        // Do not adopt/cancel a pending restore until all pre-write focus checks have passed.
        // Otherwise an early return could discard the only restore of the user's clipboard.
        let snapshot: [[String: Data]]

        if skipActivateAndClick {
            // Keep the user's caret and selection untouched.
        } else {
            await activateOwningApplication(for: element)
            await synthesizer.sleep(milliseconds: 120)

            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            await synthesizer.sleep(milliseconds: 180)

            if let inputFrame {
                await synthesizer.focusInputByClick(at: inputFrame)
                await synthesizer.sleep(milliseconds: 60)
            }
            guard !Task.isCancelled, focusedElementMatches(element) else {
                return nil
            }
        }

        snapshot = await snapshotPasteboard()

        guard await writePasteboardString(text) else {
            schedulePasteboardRestore(snapshot)
            return nil
        }

        if skipActivateAndClick { _ = await synthesizer.sleep(milliseconds: 40) }

        guard !Task.isCancelled, focusedElementMatches(element) else {
            schedulePasteboardRestore(snapshot)
            return nil
        }
        await synthesizer.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_V))
        let verified = await waitAfterPaste(
            text,
            in: element,
            assumeFocused: assumeFocused,
            strictTarget: true,
            synthesizer: synthesizer
        )

        let value = AXHelpers.copyString(kAXValueAttribute as CFString, from: element)
        let insertedRange = insertedRangeAfterPaste(of: text, in: element, value: value)

        schedulePasteboardRestore(snapshot)

        return TextInsertionRecord(
            element: element,
            inputFrame: inputFrame,
            insertedText: text,
            insertedRange: insertedRange,
            valueAfterInsertion: value,
            method: .clipboardPaste,
            verified: verified
        )
    }

    private static func pasteOverCurrentSelection(
        _ newText: String,
        record: TextInsertionRecord,
        expectedRange: CFRange,
        synthesizer: InputSynthesizer
    ) async -> TextInsertionRecord? {
        guard !Task.isCancelled, focusedElementMatches(record.element) else {
            return nil
        }
        let snapshot = await snapshotPasteboard()
        guard await writePasteboardString(newText) else {
            schedulePasteboardRestore(snapshot)
            return nil
        }

        guard !Task.isCancelled, focusedElementMatches(record.element) else {
            schedulePasteboardRestore(snapshot)
            return nil
        }
        await synthesizer.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_V))
        _ = await waitUntilInserted(
            newText,
            in: record.element,
            strictTarget: true,
            synthesizer: synthesizer
        )
        schedulePasteboardRestore(snapshot)

        return verifiedReplacementRecord(
            from: record,
            newText: newText,
            expectedRange: expectedRange,
            method: .clipboardPaste
        )
    }

    private static func verifiedReplacementRecord(
        from record: TextInsertionRecord,
        newText: String,
        expectedRange: CFRange,
        method: TextReplacementMethod
    ) -> TextInsertionRecord? {
        guard let updated = AXHelpers.copyString(kAXValueAttribute as CFString, from: record.element)
        else {
            return nil
        }

        guard utf16Substring(updated, range: expectedRange) == newText else {
            return nil
        }

        return TextInsertionRecord(
            element: record.element,
            inputFrame: record.inputFrame,
            insertedText: newText,
            insertedRange: expectedRange,
            valueAfterInsertion: updated,
            method: method,
            verified: true
        )
    }

    private static func pasteIntoFocusedElement(
        _ text: String,
        element: AXUIElement,
        inputFrame: CGRect?,
        selectedTextRange: CFRange?,
        allowAccessibilitySelectedText: Bool,
        expectedOriginalText: String?,
        requireFocusedTarget: Bool,
        synthesizer: InputSynthesizer
    ) async -> TextReplacementResult? {
        let guarded = expectedOriginalText != nil || requireFocusedTarget

        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: requireFocusedTarget
        ) else {
            return nil
        }

        if guarded && !requireFocusedTarget {
            guard prepareGuardedTarget(element, expectedOriginalText: expectedOriginalText) else {
                return nil
            }
        }

        if !guarded {
            await activateOwningApplication(for: element)
            await synthesizer.sleep(milliseconds: 120)
        }

        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: guarded
        ) else {
            return nil
        }
        if !guarded {
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        if let selectedTextRange {
            guard !guarded || validateGuardedTarget(
                element,
                expectedOriginalText: expectedOriginalText,
                requireFocusedTarget: guarded
            ) else {
                return nil
            }
            AXHelpers.setRange(selectedTextRange, attribute: kAXSelectedTextRangeAttribute as CFString, on: element)
        } else if inputFrame == nil && !guarded {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        if !guarded {
            await synthesizer.sleep(milliseconds: 180)
        }

        if allowAccessibilitySelectedText,
           (!guarded || validateGuardedTarget(
               element,
               expectedOriginalText: expectedOriginalText,
               requireFocusedTarget: guarded
           )),
           await replaceSelectedTextIfPossible(
               text,
               in: element,
               strictTarget: guarded,
               synthesizer: synthesizer
           ) {
            return TextReplacementResult(method: .accessibilitySelectedText, verified: true)
        }

        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: guarded
        ) else {
            return nil
        }
        // Take over a pending restore only once every pre-write target check has passed. If a
        // guarded operation aborts earlier, the existing pending restore must remain intact.
        let clipboardSnapshot = await snapshotPasteboard()
        // Once the pasteboard write is attempted, every exit path below must arrange a
        // change-count guarded restore.  In particular, focus can disappear after the write
        // and verification can fail; returning directly in those cases used to leave the
        // generated text on the user's clipboard.
        guard await writePasteboardString(text) else {
            schedulePasteboardRestore(clipboardSnapshot)
            return nil
        }

        // For browser / Electron fields the Accessibility focus hint above is unreliable: the
        // caret can stay wherever it was, so ⌘A selects nothing and ⌘V inserts at that point
        // instead of replacing the draft. Click into the captured input frame to place the caret
        // inside the field first, then select-all before pasting so the existing text is replaced.
        if let inputFrame, !guarded {
            await synthesizer.focusInputByClick(at: inputFrame)
            await synthesizer.sleep(milliseconds: 60)
        }

        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: guarded
        ) else {
            schedulePasteboardRestore(clipboardSnapshot)
            return nil
        }
        await synthesizer.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_A))
        await synthesizer.sleep(milliseconds: 180)
        guard !guarded || validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: guarded
        ) else {
            schedulePasteboardRestore(clipboardSnapshot)
            return nil
        }
        await synthesizer.sendCommandShortcut(keyCode: UInt16(kVK_ANSI_V))
        let verified = await waitUntilInserted(
            text,
            in: element,
            strictTarget: guarded,
            synthesizer: synthesizer
        )

        guard verified else {
            // The caller explicitly offers manual paste for an unverified write.
            // Keep the generated text available; do not restore an unrelated old value.
            return TextReplacementResult(method: .clipboardPaste, verified: false)
        }

        schedulePasteboardRestore(clipboardSnapshot)
        return TextReplacementResult(method: .clipboardPaste, verified: true)
    }

    private static func waitAfterPaste(
        _ text: String,
        in element: AXUIElement,
        assumeFocused: Bool,
        strictTarget: Bool = false,
        synthesizer: InputSynthesizer
    ) async -> Bool {
        let canVerify = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) != nil
            || focusedElementString() != nil
        if assumeFocused, !canVerify {
            await synthesizer.sleep(milliseconds: 60)
            return false
        }
        return await waitUntilInserted(
            text,
            in: element,
            strictTarget: strictTarget,
            synthesizer: synthesizer
        )
    }

    /// Waits for an exact full-field value. This is intentionally separate from
    /// `waitUntilInserted`, whose substring mode is useful for legacy unguarded paste paths but
    /// is not safe for insertion bookkeeping or cleanup.
    private static func waitUntilValue(
        _ expectedValue: String,
        in element: AXUIElement,
        strictTarget: Bool,
        synthesizer: InputSynthesizer,
        maxMilliseconds: UInt64 = 240,
        pollMilliseconds: UInt64 = 20
    ) async -> Bool {
        var waited: UInt64 = 0
        while waited < maxMilliseconds {
            guard !Task.isCancelled else { return false }
            if (!strictTarget || focusedElementMatches(element)),
               AXHelpers.copyString(kAXValueAttribute as CFString, from: element) == expectedValue {
                return true
            }
            guard await synthesizer.sleep(milliseconds: pollMilliseconds) else {
                return false
            }
            waited += pollMilliseconds
        }

        guard !Task.isCancelled,
              (!strictTarget || focusedElementMatches(element)) else {
            return false
        }
        return AXHelpers.copyString(kAXValueAttribute as CFString, from: element) == expectedValue
    }

    private static func waitUntilInserted(
        _ text: String,
        in element: AXUIElement,
        strictTarget: Bool = false,
        synthesizer: InputSynthesizer,
        maxMilliseconds: UInt64 = 240,
        pollMilliseconds: UInt64 = 20
    ) async -> Bool {
        var waited: UInt64 = 0
        while waited < maxMilliseconds {
            if replacementAppearsComplete(text, in: element, strict: strictTarget)
                || (!strictTarget && focusedElementAppearsComplete(text, matching: element)) {
                return true
            }
            await synthesizer.sleep(milliseconds: pollMilliseconds)
            waited += pollMilliseconds
        }
        return replacementAppearsComplete(text, in: element, strict: strictTarget)
            || (!strictTarget && focusedElementAppearsComplete(text, matching: element))
    }

    private static func activateOwningApplication(for element: AXUIElement) async {
        guard let pid = owningProcessIdentifier(of: element) else {
            return
        }

        let appElement = AXHelpers.application(pid: pid)
        AXUIElementPerformAction(appElement, kAXRaiseAction as CFString)
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    private static func owningProcessIdentifier(of element: AXUIElement) -> pid_t? {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    private static func isOwningApplicationFrontmost(for element: AXUIElement) -> Bool {
        guard let pid = owningProcessIdentifier(of: element) else {
            return false
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Validates the target immediately before every guarded mutation. AXValue must be
    /// readable when an expected snapshot is supplied; an unreadable field is never treated as
    /// empty or as a match. A guarded operation also requires the owning app to remain frontmost
    /// and its focused AX element to be the exact captured element.
    private static func validateGuardedTarget(
        _ element: AXUIElement,
        expectedOriginalText: String?,
        requireFocusedTarget: Bool
    ) -> Bool {
        guard expectedOriginalText != nil || requireFocusedTarget else {
            return true
        }
        guard isOwningApplicationFrontmost(for: element) else {
            return false
        }
        if requireFocusedTarget {
            guard focusedElementMatches(element) else {
                return false
            }
        }
        if let expectedOriginalText {
            guard let current = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) else {
                return false
            }
            guard current == expectedOriginalText else {
                return false
            }
        }
        return true
    }

    private static func prepareGuardedTarget(
        _ element: AXUIElement,
        expectedOriginalText: String?
    ) -> Bool {
        guard validateGuardedTarget(
            element,
            expectedOriginalText: expectedOriginalText,
            requireFocusedTarget: false
        ) else {
            return false
        }
        guard let pid = owningProcessIdentifier(of: element),
              let window = AXHelpers.copyUIElement(kAXWindowAttribute as CFString, from: element),
              let focusedWindow = AXHelpers.copyUIElement(kAXFocusedWindowAttribute as CFString, from: AXHelpers.application(pid: pid)),
              CFEqual(window, focusedWindow) else { return false }
        guard AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            return false
        }
        return focusedElementMatches(element)
            && validateGuardedTarget(
                element,
                expectedOriginalText: expectedOriginalText,
                requireFocusedTarget: true
            )
    }

    private static func focusedElementMatches(_ element: AXUIElement) -> Bool {
        guard let pid = owningProcessIdentifier(of: element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return false
        }
        let appElement = AXHelpers.application(pid: pid)
        guard let focused = AXHelpers.copyUIElement(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement
        ) else {
            return false
        }
        return CFEqual(focused, element)
    }

    private static func focusedElementAllowsKeyboardSwap(_ element: AXUIElement) -> Bool {
        guard let pid = owningProcessIdentifier(of: element) else {
            return false
        }

        let appElement = AXHelpers.application(pid: pid)
        if let focused = AXHelpers.copyUIElement(kAXFocusedUIElementAttribute as CFString, from: appElement) {
            return CFEqual(focused, element)
        }

        // An AX focus query failure is not evidence that an arbitrary text role is the target.
        // Fail closed instead of allowing keyboard selection/paste into another field.
        return false
    }

    private static func replaceSelectedTextIfPossible(
        _ text: String,
        in element: AXUIElement,
        strictTarget: Bool = false,
        synthesizer: InputSynthesizer
    ) async -> Bool {
        selectCurrentTextIfPossible(in: element)
        let setError = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard setError == .success else {
            return false
        }

        return await waitUntilInserted(
            text,
            in: element,
            strictTarget: strictTarget,
            synthesizer: synthesizer
        )
    }

    private static func replacementAppearsComplete(
        _ text: String,
        in element: AXUIElement,
        strict: Bool = false
    ) -> Bool {
        guard let value = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) else {
            return false
        }

        return strict ? value == text : valueContainsInsertedText(text, in: value)
    }

    private static func valueContainsInsertedText(_ text: String, in value: String) -> Bool {
        normalized(value) == normalized(text) || normalized(value).contains(normalized(text))
    }

    private static func focusedElementAppearsComplete(
        _ text: String,
        matching target: AXUIElement
    ) -> Bool {
        guard focusedElementMatches(target),
              let focused = focusedElement(),
              CFEqual(focused, target) else {
            return false
        }
        return replacementAppearsComplete(text, in: focused)
    }

    private static func focusedElementString() -> String? {
        guard let focused = focusedElement() else {
            return nil
        }
        return AXHelpers.copyString(kAXValueAttribute as CFString, from: focused)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXHelpers.systemWide()
        guard let focusedValue = AXHelpers.copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWide
        ) else {
            return nil
        }
        return AXHelpers.uiElement(from: focusedValue)
    }

    private static func selectCurrentTextIfPossible(in element: AXUIElement) {
        guard let currentText = AXHelpers.copyString(kAXValueAttribute as CFString, from: element) else {
            return
        }

        var range = CFRange(location: 0, length: currentText.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return
        }

        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
    }

    private static func insertedRangeAfterPaste(
        of text: String,
        in element: AXUIElement,
        value: String?
    ) -> CFRange? {
        let length = text.utf16.count
        if let selected = AXHelpers.copyRange(kAXSelectedTextRangeAttribute as CFString, from: element) {
            let end = selected.location + selected.length
            let start = end - length
            if start >= 0 {
                let candidate = CFRange(location: start, length: length)
                if let value {
                    if utf16Substring(value, range: candidate) == text {
                        return candidate
                    }
                    return nearestOccurrenceRange(of: text, in: value, near: start)
                }
                return candidate
            }
        }

        guard let value else {
            return nil
        }
        return uniqueOccurrenceRange(of: text, in: value)
    }

    // Snapshot every clipboard item and type as Sendable data so images, files, and rich text
    // are restored after paste — not just plain text. Without this, pasting a generated reply
    // while an image is on the clipboard would wipe the image and never restore it.
    //
    // Restores are coordinated process-wide. Two of our pastes can overlap (raw insertion, then
    // the Gemini swap ~1.5s later): if the first paste's delayed restore fires while the second
    // paste's ⌘V is still being processed by an Electron app, the app pastes the *user's old
    // clipboard* over the selection. So a new paste takes over any pending restore (adopting its
    // original snapshot), and a restore only runs if the board still holds what we wrote.
    private final class RestoreCoordinator: @unchecked Sendable {
        struct Pending {
            let workItem: DispatchWorkItem
            let snapshot: [[String: Data]]
            let expectedChangeCount: Int
        }

        private let lock = NSLock()
        private var pending: Pending?
        private var lastPublishedChangeCount: Int?

        func notePublished(changeCount: Int) {
            lock.lock()
            lastPublishedChangeCount = changeCount
            lock.unlock()
        }

        func publishedChangeCount() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return lastPublishedChangeCount
        }

        /// Cancels a pending restore. Its original snapshot may be adopted only while the board
        /// still contains the app-owned write; if the user copied something new, return nil and
        /// let the caller snapshot that latest clipboard instead.
        func takeOverPendingIfOwned(currentChangeCount: Int) -> [[String: Data]]? {
            lock.lock()
            defer { lock.unlock() }
            guard let current = pending else {
                return nil
            }
            pending = nil
            current.workItem.cancel()
            guard ClipboardOwnershipPolicy.canAdoptPending(
                pendingWriteChangeCount: current.expectedChangeCount,
                currentChangeCount: currentChangeCount
            ) else {
                return nil
            }
            return current.snapshot
        }

        func setPending(_ value: Pending) {
            lock.lock()
            pending?.workItem.cancel()
            pending = value
            lock.unlock()
        }

        func consumeIfOwned(currentChangeCount: Int, expectedChangeCount: Int) -> Bool {
            lock.lock()
            if let pending, pending.expectedChangeCount == expectedChangeCount {
                self.pending = nil
            }
            lock.unlock()
            return ClipboardOwnershipPolicy.shouldRestore(
                expectedWriteChangeCount: expectedChangeCount,
                currentChangeCount: currentChangeCount
            )
        }
    }

    private static let restoreCoordinator = RestoreCoordinator()

    private static func snapshotPasteboard() async -> [[String: Data]] {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            if let snapshot = restoreCoordinator.takeOverPendingIfOwned(
                currentChangeCount: pasteboard.changeCount
            ) {
                // The board still holds our own earlier text; adopt its original user snapshot.
                return snapshot
            }

            return pasteboard.pasteboardItems?.compactMap { item in
                var typed: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        typed[type.rawValue] = data
                    }
                }
                return typed.isEmpty ? nil : typed
            } ?? []
        }
    }

    private static func writePasteboardString(_ text: String) async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let ok = pasteboard.setString(text, forType: .string)
            // Capture ownership at publication, not after waiting for the receiving app.
            // A user copy during verification must never become "our" restoration token.
            restoreCoordinator.notePublished(changeCount: pasteboard.changeCount)
            return ok
        }
    }

    private static func schedulePasteboardRestore(_ snapshot: [[String: Data]]) {
        guard let expectedChangeCount = restoreCoordinator.publishedChangeCount() else { return }
        let workItem = DispatchWorkItem {
            // If the user (or another app) copied something since our write, leave it alone.
            let currentChangeCount = NSPasteboard.general.changeCount
            guard restoreCoordinator.consumeIfOwned(
                currentChangeCount: currentChangeCount,
                expectedChangeCount: expectedChangeCount
            ) else {
                return
            }
            restorePasteboard(snapshot)
        }
        restoreCoordinator.setPending(.init(
            workItem: workItem,
            snapshot: snapshot,
            expectedChangeCount: expectedChangeCount
        ))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private static func restorePasteboard(_ snapshot: [[String: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else {
            // An empty clipboard is a real snapshot. Clearing our temporary paste value is the
            // correct restoration; returning early would leave generated text behind.
            return
        }
        let restoredItems = snapshot.map { typed -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in typed {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TextReplacer {
    nonisolated static func utf16Substring(_ s: String, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else {
            return nil
        }

        let utf16 = s.utf16
        let utf16Count = utf16.count
        guard
            let startOffset = Int(exactly: range.location),
            let rangeLength = Int(exactly: range.length)
        else {
            return nil
        }
        let (endOffset, overflow) = startOffset.addingReportingOverflow(rangeLength)
        guard !overflow, startOffset <= utf16Count, endOffset <= utf16Count else {
            return nil
        }

        let start = utf16.index(utf16.startIndex, offsetBy: startOffset)
        let end = utf16.index(utf16.startIndex, offsetBy: endOffset)
        guard let lower = String.Index(start, within: s), let upper = String.Index(end, within: s) else {
            return nil
        }
        return String(s[lower..<upper])
    }

    static func utf16OccurrenceRanges(of needle: String, in haystack: String) -> [CFRange] {
        guard !needle.isEmpty else {
            return []
        }

        var ranges: [CFRange] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex {
            guard let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) else {
                break
            }
            let location = haystack.utf16.distance(from: haystack.utf16.startIndex, to: found.lowerBound)
            ranges.append(CFRange(location: location, length: needle.utf16.count))
            searchStart = found.upperBound
        }
        return ranges
    }

    static func nearestOccurrenceRange(of needle: String, in haystack: String, near location: CFIndex) -> CFRange? {
        let ranges = utf16OccurrenceRanges(of: needle, in: haystack)
        return ranges.min { a, b in
            let da = abs(a.location - location)
            let db = abs(b.location - location)
            if da == db {
                return a.location < b.location
            }
            return da < db
        }
    }

    static func uniqueOccurrenceRange(of needle: String, in haystack: String) -> CFRange? {
        let ranges = utf16OccurrenceRanges(of: needle, in: haystack)
        guard ranges.count == 1 else {
            return nil
        }
        return ranges[0]
    }

    static func resolvedInsertedRange(
        of needle: String,
        in haystack: String,
        preferredLocation: CFIndex?
    ) -> CFRange? {
        if let preferredLocation {
            let candidate = CFRange(location: preferredLocation, length: needle.utf16.count)
            if utf16Substring(haystack, range: candidate) == needle {
                return candidate
            }
            return nearestOccurrenceRange(of: needle, in: haystack, near: preferredLocation)
        }
        return uniqueOccurrenceRange(of: needle, in: haystack)
    }

    static func rangeForReplacingInsertion(
        insertedText: String,
        insertedRange: CFRange?,
        valueAfterInsertion: String?,
        currentValue: String
    ) -> CFRange? {
        if let snapshot = valueAfterInsertion, snapshot != currentValue {
            return nil
        }

        if let insertedRange, utf16Substring(currentValue, range: insertedRange) == insertedText {
            return insertedRange
        }

        return uniqueOccurrenceRange(of: insertedText, in: currentValue)
    }
}

/// CF handle wrapper so synthesizer job closures can be `@Sendable`.
private struct AXElementBox: @unchecked Sendable {
    let value: AXUIElement
    init(_ value: AXUIElement) {
        self.value = value
    }
}

private func optionalCFRangesEqual(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (lhs?, rhs?):
        lhs.location == rhs.location && lhs.length == rhs.length
    default:
        false
    }
}
