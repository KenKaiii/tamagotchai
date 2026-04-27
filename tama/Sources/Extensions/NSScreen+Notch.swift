import AppKit

extension NSScreen {
    /// Whether this screen has a hardware notch (e.g. MacBook Pro 2021+).
    var hasNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// The size of the hardware notch, or a sensible fallback for non-notch displays.
    /// Width is calculated from the gap between the left and right auxiliary areas, with
    /// a small +4pt fudge so adjacent UI (wings, overlay shapes) tucks in seamlessly.
    /// Height comes from `safeAreaInsets.top` (which equals the notch height on notch displays).
    var notchSize: NSSize {
        if let leftPadding = auxiliaryTopLeftArea?.width,
           let rightPadding = auxiliaryTopRightArea?.width
        {
            let width = frame.width - leftPadding - rightPadding + 4
            let height = safeAreaInsets.top
            return NSSize(width: width, height: max(height, NSStatusBar.system.thickness))
        }
        // Fallback for non-notch displays: use menu bar height and a reasonable width.
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        return NSSize(width: 220, height: max(menuBarHeight, NSStatusBar.system.thickness))
    }

    /// The exact size of the hardware notch (no fudge). Used by the virtual notch overlay
    /// so it sits pixel-perfect on top of the real notch on notched MacBooks. Falls back
    /// to a reasonable size on non-notch displays.
    var exactNotchSize: NSSize {
        if let leftPadding = auxiliaryTopLeftArea?.width,
           let rightPadding = auxiliaryTopRightArea?.width
        {
            let width = frame.width - leftPadding - rightPadding
            let height = safeAreaInsets.top
            return NSSize(width: width, height: max(height, NSStatusBar.system.thickness))
        }
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        return NSSize(width: 200, height: max(menuBarHeight, NSStatusBar.system.thickness))
    }

    /// The frame of the hardware notch in screen coordinates, positioned at top-center.
    var notchFrame: NSRect {
        let size = notchSize
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
