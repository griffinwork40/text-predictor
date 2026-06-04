// Overlay.swift — borderless NSPanel that renders ghost text at the caret.
//
// Floating, click-through, non-activating. We don't try to fight rich-text
// styling in Notes for M1A — just SF Pro 15pt at 45% opacity, baseline-aligned
// to the right of the caret rect. Good-enough until M2.

import AppKit

@MainActor
final class Overlay {
    private let panel: NSPanel
    private let label: NSTextField

    private(set) var isVisible = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 15)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.45)
        label.backgroundColor = .clear
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.maximumNumberOfLines = 1  // M1A: no wrap

        panel.contentView = label
    }

    /// Show ghost text at the given caret rect (AppKit screen coords).
    /// If `rect` is nil, falls back to a position near the mouse cursor.
    func show(text: String, near rect: CGRect?) {
        label.stringValue = text
        label.sizeToFit()
        let size = label.frame.size

        let origin: NSPoint
        if let r = rect, r.width.isFinite, r.height.isFinite,
            r.origin.x.isFinite, r.origin.y.isFinite
        {
            // Align the panel's TOP edge with the caret rect's TOP edge in
            // AppKit screen coords. This works for two cases that both occur
            // in practice:
            //
            //  (1) AX returned a proper caret rect with height ≈ line height.
            //      After Y-flip, r.maxY is the AppKit Y of the line's top.
            //      Panel top → line top, panel extends down by panel.height,
            //      text sits centered on the line. Correct.
            //
            //  (2) AX returned a degenerate rect (height ≈ 0). Notes does
            //      this when the caret sits between glyphs. The AX rect's
            //      origin.y points to the TOP of the caret line per AX
            //      convention; after flip both minY and maxY collapse to
            //      that point. Using r.maxY again gives the line's top.
            //      Same result. Correct.
            //
            // The previous M1A revision used `r.minY` directly, which in
            // case (2) was the line top and made the panel float one full
            // line ABOVE the caret. That's the bug this fixes.
            let caretTopY = max(r.minY, r.maxY)
            origin = NSPoint(x: r.maxX + 2, y: caretTopY - size.height)
            log.debug(
                """
                Overlay: caret rect AppKit \(NSStringFromRect(r), privacy: .public) \
                → panel origin \(NSStringFromPoint(origin), privacy: .public) size \
                \(NSStringFromSize(size), privacy: .public)
                """
            )
        } else {
            // Fallback — no caret geometry available. Place near mouse so
            // user can at least see what was suggested.
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + 16, y: mouse.y - 24)
            log.debug("Overlay: no caret rect, falling back to mouse position")
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
    }
}
