import ApplicationServices
import CoreGraphics
import Foundation

enum AXReadError: LocalizedError {
    case focusedElementUnavailable(AXError)
    case focusedWindowUnavailable
    case selectionSnapshotMismatch

    var errorDescription: String? {
        switch self {
        case let .focusedElementUnavailable(error):
            "Focused input could not be read through Accessibility (\(error.rawValue))."
        case .focusedWindowUnavailable:
            "Focused window could not be read through Accessibility."
        case .selectionSnapshotMismatch:
            "The selected text did not match the captured field value."
        }
    }
}

enum AXHelpers {
    static let messagingTimeout: Float = 0.15

    static func applyMessagingTimeout(_ element: AXUIElement, seconds: Float = messagingTimeout) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func systemWide() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        applyMessagingTimeout(element)
        return element
    }

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        applyMessagingTimeout(element)
        return element
    }

    /// `CFGetTypeID` is the real check: `as?` always succeeds for Core Foundation types.
    static func uiElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    static func axValue(from value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value as AnyObject, to: AXValue.self)
    }

    static func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    static func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributed = value as? NSAttributedString {
            return attributed.string
        }

        return nil
    }

    static func copyUIElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }
        guard let copied = uiElement(from: value) else {
            return nil
        }
        applyMessagingTimeout(copied)
        return copied
    }

    static func copyRange(_ attribute: CFString, from element: AXUIElement) -> CFRange? {
        guard
            let value = copyAttribute(attribute, from: element),
            let axValue = axValue(from: value),
            AXValueGetType(axValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    @discardableResult
    static func setRange(_ range: CFRange, attribute: CFString, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, rangeValue) == .success
    }

    static func copyChildren(from element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(kAXChildrenAttribute as CFString, from: element) else {
            return []
        }

        let children: [AXUIElement]
        if let elements = value as? [AXUIElement] {
            children = elements
        } else if CFGetTypeID(value) == CFArrayGetTypeID() {
            children = cfArrayUIElements(unsafeDowncast(value, to: CFArray.self))
        } else {
            return []
        }

        for child in children {
            applyMessagingTimeout(child)
        }
        return children
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = copyAttribute(kAXPositionAttribute as CFString, from: element),
            let sizeValue = copyAttribute(kAXSizeAttribute as CFString, from: element),
            let position = axValue(from: positionValue),
            let sizeAX = axValue(from: sizeValue)
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero

        guard
            AXValueGetValue(position, .cgPoint, &point),
            AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private static func cfArrayUIElements(_ cfArray: CFArray) -> [AXUIElement] {
        let count = CFArrayGetCount(cfArray)
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfArray, index) else {
                continue
            }
            let item = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as CFTypeRef
            if let element = uiElement(from: item) {
                result.append(element)
            }
        }
        return result
    }
}

/// CF handle wrapper for hopping AX work off the main actor.
struct UncheckedAXElement: @unchecked Sendable {
    let value: AXUIElement
    init(_ value: AXUIElement) {
        self.value = value
    }
}
