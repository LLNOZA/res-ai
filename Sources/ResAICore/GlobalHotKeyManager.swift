import Carbon
import CoreGraphics
import Foundation

public enum HotKeyError: LocalizedError {
    case eventTapCreateFailed
    case runLoopSourceCreateFailed
    case eventTapRunLoopUnavailable

    public var errorDescription: String? {
        switch self {
        case .eventTapCreateFailed:
            "Failed to create keyboard event tap. Check Accessibility/Input Monitoring permissions."
        case .runLoopSourceCreateFailed:
            "Failed to create keyboard event tap run loop source."
        case .eventTapRunLoopUnavailable:
            "The keyboard event tap thread did not respond in time. Try Repair Shortcuts or check Accessibility/Input Monitoring permissions."
        }
    }
}

public enum HotKeyTapDisableReason: String, Sendable {
    case timeout
    case userInput
    case silentDisable
}

/// Global shortcut tap. Callbacks hop to `@MainActor` via `Task`.
///
/// `ModifierChordDetector` is mutated only on the `ai.res.resai.event-tap` thread
/// (inside the CGEvent tap callback). `register` / `unregister` wait until the
/// previous source is removed from that run loop before touching detector state.
public final class GlobalHotKeyManager: @unchecked Sendable {
    /// Tap / press / matching fields: written from `register` after `unregister` waits,
    /// then read from the event-tap callback. `repairTapIfNeeded` may also touch `eventTap`
    /// and `isPressed` from the main actor; those two are protected by `lock`.
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedUserInfo: UnsafeMutableRawPointer?
    private var keyCode: UInt16 = UInt16(kVK_ANSI_J)
    private var requiredFlags: CGEventFlags = [.maskCommand, .maskShift]
    private let callback: @Sendable () -> Void
    private let releaseCallback: (@Sendable () -> Void)?
    /// Diagnostic hook: fired after the tap was re-enabled following a system disable.
    public var onTapReenabled: (@Sendable () -> Void)?
    /// Diagnostic hook with the actual reason supplied by Core Graphics. This is
    /// separate from `onTapReenabled` for source compatibility with existing users.
    public var onTapDisabled: (@Sendable (HotKeyTapDisableReason) -> Void)?
    private var isPressed = false
    private var isModifierChordMode = false
    /// Only touched from the event-tap callback thread. See type comment above.
    private var chordDetector = ModifierChordDetector(requiredFlags: [.maskSecondaryFn, .maskCommand])
    private var storedRegistration: StoredRegistration?
    private var lastEventAt: TimeInterval = 0
    private var _registrationGeneration: UInt64 = 0

    private enum StoredRegistration {
        case key(code: UInt32, modifiers: UInt32)
        case chord(CGEventFlags)
    }

    /// `callback` fires once per physical press (autorepeat is ignored). When `onRelease` is
    /// supplied, the tap also listens for the matching keyUp so callers can implement
    /// push-to-talk style interactions.
    public init(callback: @escaping @Sendable () -> Void, onRelease: (@Sendable () -> Void)? = nil) {
        self.callback = callback
        self.releaseCallback = onRelease
    }

    deinit {
        unregister()
    }

    public func registerDefaultHotKey() throws {
        try register(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey), id: 1)
    }

    public func register(_ shortcut: HotKeyShortcut, id: UInt32 = 1) throws {
        try register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id)
    }

    public func register(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1) throws {
        unregister()

        isModifierChordMode = false
        resetStateOnCurrentThread()
        self.keyCode = UInt16(keyCode)
        self.requiredFlags = HotKeyModifierMatcher.eventFlags(forCarbonModifiers: modifiers)

        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if releaseCallback != nil {
            mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        try installTap(mask: mask)
        storedRegistration = .key(code: keyCode, modifiers: modifiers)
    }

    /// Modifier-only chord (voice trigger `fn + ⌘`). `flagsChanged` is never swallowed.
    public func register(modifierChord flags: CGEventFlags, id _: UInt32 = 1) throws {
        unregister()

        isModifierChordMode = true
        resetStateOnCurrentThread()
        chordDetector = ModifierChordDetector(requiredFlags: flags)

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        try installTap(mask: mask)
        storedRegistration = .chord(flags)
    }

    private func installTap(mask: CGEventMask) throws {
        let unmanaged = Unmanaged.passRetained(self)
        let userData = unmanaged.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS disables a tap whose callback stalls. Re-enable immediately,
                    // reset physical state on this same tap thread, and release a pending
                    // push-to-talk press exactly once if its key-up was lost.
                    manager.lock.lock()
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    manager.lock.unlock()
                    let reason: HotKeyTapDisableReason = type == .tapDisabledByTimeout
                        ? .timeout
                        : .userInput
                    manager.resetStateFromTapThread()
                    manager.emitTapDisabled(reason)
                    manager.emitTapReenabled()
                    return nil
                }

                // Our own input synthesis is intentionally invisible to global
                // shortcuts and to liveness accounting.
                guard !SyntheticEventMarker.isSynthetic(event) else {
                    return Unmanaged.passUnretained(event)
                }

                manager.noteTapEvent()

                if manager.isModifierChordMode {
                    return manager.handleModifierChord(type: type, event: event)
                }

                guard type == .keyDown || type == .keyUp else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyUp {
                    // Modifiers may already be released by the time the letter key comes up,
                    // so match on key code alone while a press is outstanding.
                    if manager.matchesKeyCode(event), manager.takePressed() {
                        manager.emitReleased()
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }

                if manager.matches(event) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat {
                        manager.setPressed(true)
                        manager.emitPressed()
                    }
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: userData
        ) else {
            unmanaged.release()
            throw HotKeyError.eventTapCreateFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            unmanaged.release()
            throw HotKeyError.runLoopSourceCreateFailed
        }

        guard EventTapRunLoop.shared.add(source) else {
            CFMachPortInvalidate(tap)
            // The add block may still be queued. Queue its matching removal before
            // releasing the retained manager: a late run-loop wake can otherwise run
            // the add block (or a callback) after this branch has returned.
            let release = {
                unmanaged.release()
            }
            let removed = EventTapRunLoop.shared.remove(source, completion: release)
            if !removed && !EventTapRunLoop.shared.isAvailable {
                // No helper run loop ever became available, so the source could not
                // have been installed and the queued completion cannot run.
                release()
            }
            throw HotKeyError.eventTapRunLoopUnavailable
        }
        lock.lock()
        eventTap = tap
        runLoopSource = source
        retainedUserInfo = userData
        _registrationGeneration &+= 1
        lock.unlock()
        noteTapEvent()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleModifierChord(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime

        if type == .flagsChanged {
            applyChordAction(chordDetector.handle(flags: event.flags, at: now))
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if !Self.isModifierKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                applyChordAction(chordDetector.handleNonModifierKeyDown(at: now))
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            if !Self.isModifierKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) {
                chordDetector.handleNonModifierKeyUp()
            }
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func applyChordAction(_ action: ModifierChordDetector.Action) {
        switch action {
        case .pressed:
            setPressedFromTapThread(true)
            emitPressed()
        case .released:
            setPressedFromTapThread(false)
            emitReleased()
        case .none:
            break
        }
    }

    private func emitPressed() {
        let callback = callback
        Task { @MainActor in
            callback()
        }
    }

    private func emitReleased() {
        let releaseCallback = releaseCallback
        Task { @MainActor in
            releaseCallback?()
        }
    }

    private func emitTapReenabled() {
        let hook = onTapReenabled
        Task { @MainActor in
            hook?()
        }
    }

    private func setPressed(_ value: Bool) {
        lock.lock()
        isPressed = value
        lock.unlock()
    }

    /// Called by the event-tap thread for chord state. Keeping this write on the
    /// same thread as `ModifierChordDetector` makes disable/re-enable transitions
    /// deterministic while the main actor is free to inspect the snapshot.
    private func setPressedFromTapThread(_ value: Bool) {
        lock.lock()
        isPressed = value
        lock.unlock()
    }

    private func takePressed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasPressed = isPressed
        isPressed = false
        return wasPressed
    }

    private static func isModifierKeyCode(_ keyCode: Int64) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_Function, kVK_CapsLock:
            true
        default:
            false
        }
    }

    /// Seconds since this tap last saw any event (including non-matching keys).
    public var secondsSinceLastEvent: TimeInterval {
        lock.lock()
        let at = lastEventAt
        lock.unlock()
        guard at > 0 else {
            return .greatestFiniteMagnitude
        }
        return ProcessInfo.processInfo.systemUptime - at
    }

    private func noteTapEvent() {
        lock.lock()
        lastEventAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func resetStateFromTapThread() {
        let chordWasHeld = isModifierChordMode && chordDetector.reset()
        lock.lock()
        let keyWasHeld = isPressed
        isPressed = false
        lock.unlock()
        if chordWasHeld || (!isModifierChordMode && keyWasHeld) {
            emitReleased()
        }
    }

    private func resetStateOnCurrentThread() {
        lock.lock()
        isPressed = false
        lock.unlock()
        // This is only used before a new source is installed, when no tap callback
        // can be observing the detector. The next callback starts with fresh state.
        _ = chordDetector.reset()
    }


    /// Whether a tap is installed and currently enabled.
    public var isTapEnabled: Bool {
        lock.lock()
        let tap = eventTap
        lock.unlock()
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Whether a Core Graphics tap and its run-loop source are currently owned by
    /// this manager. This distinguishes an unregistered slot from a disabled tap.
    public var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil && runLoopSource != nil
    }

    /// Monotonic install count, useful for diagnostics and lifecycle tests.
    public var registrationGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _registrationGeneration
    }

    /// Re-enables a tap the system switched off without delivering a disable event.
    /// Returns true when a repair was needed.
    @discardableResult
    public func repairTapIfNeeded() -> Bool {
        lock.lock()
        let tap = eventTap
        lock.unlock()
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        _ = EventTapRunLoop.shared.performAndWait { [weak self] _ in
            self?.resetStateFromTapThread()
        }
        emitTapDisabled(.silentDisable)
        emitTapReenabled()
        return true
    }

    /// Tear down and reinstall the tap with the last registration.
    /// After Secure Keyboard Entry, sleep/wake, or a lock screen, `tapIsEnabled` can
    /// stay true while the tap no longer delivers events. Re-enable is not enough.
    public func recreateTap() throws {
        switch storedRegistration {
        case .key(let code, let modifiers):
            try register(keyCode: code, modifiers: modifiers)
        case .chord(let flags):
            try register(modifierChord: flags)
        case nil:
            break
        }
    }

    /// Another process has enabled secure keyboard entry (password field, Terminal's
    /// "Secure Keyboard Entry", some password managers). While it is on, event taps
    /// receive no keyboard events at all, so every global shortcut looks dead.
    public static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    public func unregister() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        let userInfo = retainedUserInfo
        eventTap = nil
        runLoopSource = nil
        retainedUserInfo = nil
        storedRegistration = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let tap {
            CFMachPortInvalidate(tap)
        }

        if let source {
            // Reset and release on the tap thread. If the thread does not respond
            // before the finite wait expires, the queued completion still owns the
            // release and prevents a use-after-free.
            let release = {
                if let userInfo {
                    Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).release()
                }
            }
            let removed = EventTapRunLoop.shared.remove(
                source,
                beforeRemove: { [weak self] in self?.resetStateFromTapThread() },
                completion: release
            )
            if !removed && !EventTapRunLoop.shared.isAvailable {
                // No callback can be running when the helper loop never came up;
                // complete the retained-object release locally.
                release()
            }
        } else {
            resetStateOnCurrentThread()
            if let userInfo {
                Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).release()
            }
        }
    }

    private func matchesKeyCode(_ event: CGEvent) -> Bool {
        UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
    }

    private func matches(_ event: CGEvent) -> Bool {
        guard matchesKeyCode(event) else {
            return false
        }

        // Match the complete modifier chord. In particular, ⌘⇧⌥J must not steal
        // the ⌘⇧J shortcut, and Caps Lock / fn must not be silently ignored.
        return HotKeyModifierMatcher.matches(eventFlags: event.flags, requiredFlags: requiredFlags)
    }

    private func emitTapDisabled(_ reason: HotKeyTapDisableReason) {
        let hook = onTapDisabled
        Task { @MainActor in
            hook?(reason)
        }
    }
}
