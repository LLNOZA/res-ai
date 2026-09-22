import Carbon
import CoreGraphics
import Foundation

/// Session-scoped Escape interceptor. Enabled only while voice input is listening so
/// Escape is not swallowed the rest of the time.
///
/// The tap lives on `ai.res.resai.event-tap`. `onCancel` hops to `@MainActor` via `Task`.
public final class EscapeKeyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedUserInfo: UnsafeMutableRawPointer?
    private var onCancel: (@Sendable () -> Void)?
    private let escapeKeyCode = UInt16(kVK_Escape)

    public init() {}

    deinit {
        stop()
    }

    /// Starts intercepting unmodified Escape. Returns `false` if the event tap could not be created.
    @discardableResult
    public func start(onCancel: @escaping @Sendable () -> Void) -> Bool {
        stop()
        lock.lock()
        self.onCancel = onCancel
        lock.unlock()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
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

                let monitor = Unmanaged<EscapeKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                guard !SyntheticEventMarker.isSynthetic(event) else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.lock.lock()
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    monitor.lock.unlock()
                    return nil
                }

                guard type == .keyDown || type == .keyUp else {
                    return Unmanaged.passUnretained(event)
                }

                guard monitor.matchesUnmodifiedEscape(event) else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    monitor.emitCancel()
                }
                return nil
            },
            userInfo: userData
        ) else {
            unmanaged.release()
            lock.lock()
            self.onCancel = nil
            lock.unlock()
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            unmanaged.release()
            lock.lock()
            self.onCancel = nil
            lock.unlock()
            return false
        }

        guard EventTapRunLoop.shared.add(source) else {
            _ = EventTapRunLoop.shared.remove(source)
            CFMachPortInvalidate(tap)
            unmanaged.release()
            lock.lock()
            self.onCancel = nil
            lock.unlock()
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        runLoopSource = source
        retainedUserInfo = userData
        lock.unlock()
        return true
    }

    public func stop() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        let userInfo = retainedUserInfo
        eventTap = nil
        runLoopSource = nil
        retainedUserInfo = nil
        onCancel = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        if let source {
            let release = {
                if let userInfo {
                    Unmanaged<EscapeKeyMonitor>.fromOpaque(userInfo).release()
                }
            }
            let removed = EventTapRunLoop.shared.remove(source, completion: release)
            if !removed && !EventTapRunLoop.shared.isAvailable {
                release()
            }
        } else if let userInfo {
            Unmanaged<EscapeKeyMonitor>.fromOpaque(userInfo).release()
        }
    }

    private func emitCancel() {
        lock.lock()
        let onCancel = onCancel
        lock.unlock()
        Task { @MainActor in
            onCancel?()
        }
    }

    private func matchesUnmodifiedEscape(_ event: CGEvent) -> Bool {
        guard UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == escapeKeyCode else {
            return false
        }

        let flags = event.flags
        return !flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
    }
}
