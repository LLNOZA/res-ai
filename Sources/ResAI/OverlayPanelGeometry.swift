import AppKit

/// Shared origin / clamp math for overlay panels (HUD and voice pill).
enum OverlayPanelGeometry {
    static func origin(
        for size: NSSize,
        inputFrame: CGRect?,
        gapAboveInput: CGFloat,
        anchoredCenterX: CGFloat? = nil
    ) -> CGPoint {
        let screen = screen(for: inputFrame) ?? NSScreen.main
        guard let screen else {
            return CGPoint(x: 120, y: 120)
        }

        let visible = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat

        if let inputFrame {
            let centerX = anchoredCenterX ?? inputFrame.midX
            x = clamp(centerX - size.width / 2, min: visible.minX + 16, max: visible.maxX - size.width - 16)
            let topOriginY = desktopTop - inputFrame.minY + gapAboveInput
            y = clamp(topOriginY, min: visible.minY + 16, max: visible.maxY - size.height - 16)
        } else if let anchoredCenterX {
            x = clamp(anchoredCenterX - size.width / 2, min: visible.minX + 16, max: visible.maxX - size.width - 16)
            y = visible.minY + 72
        } else {
            x = visible.midX - size.width / 2
            y = visible.minY + 72
        }

        return CGPoint(x: x, y: y)
    }

    static func screen(for frame: CGRect?) -> NSScreen? {
        guard let frame else {
            return NSScreen.main
        }

        let center = CGPoint(x: frame.midX, y: desktopTop - frame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(center)
        } ?? NSScreen.main
    }

    // AX coordinates share the primary display's top-left origin, including
    // displays arranged above or below it. Do not flip relative to each screen.
    private static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}
