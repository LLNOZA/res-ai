import CoreGraphics
import Foundation

/// Pure geometry for detecting a menu-bar status item hidden by the notch or overflow.
public enum MenuBarIconVisibility: Sendable {
    /// Horizontal gap between the left and right auxiliary menu-bar areas (the notch).
    public static func notchGapXRange(leftArea: CGRect?, rightArea: CGRect?) -> Range<CGFloat>? {
        guard let leftArea, let rightArea, !leftArea.isEmpty, !rightArea.isEmpty else {
            return nil
        }
        let minX = leftArea.maxX
        let maxX = rightArea.minX
        guard minX < maxX else {
            return nil
        }
        return minX..<maxX
    }

    /// Hidden when the button has no window, the window is occluded, or its frame sits in the notch gap.
    public static func isHidden(
        windowExists: Bool,
        occlusionContainsVisible: Bool,
        windowFrame: CGRect,
        notchGapXRange: Range<CGFloat>?
    ) -> Bool {
        if !windowExists {
            return true
        }
        if !occlusionContainsVisible {
            return true
        }
        if let notchGapXRange, intersects(windowFrame, gap: notchGapXRange) {
            return true
        }
        return false
    }

    public static func intersects(_ frame: CGRect, gap: Range<CGFloat>) -> Bool {
        frame.minX < gap.upperBound && frame.maxX > gap.lowerBound
    }
}
