// Overlay.swift — borderless NSPanel that renders ghost text at the caret.
//
// Floating, click-through, non-activating. We don't try to fight rich-text
// styling in Notes for M1A — just SF Pro 15pt at 45% opacity, baseline-aligned
// to the right of the caret rect. Good-enough until M2.

import AppKit

private func _tpDebug(_ msg: String) {
    TextPredictorConfig.debugLog(msg)
}

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
        _tpDebug(">>> Overlay.show(text: '\(text.prefix(40))…', rect=\(String(describing: rect))")
        label.stringValue = text
        label.sizeToFit()
        let size = label.frame.size

        let origin: NSPoint
        if let r = rect, r.width.isFinite, r.height.isFinite,
            r.origin.x.isFinite, r.origin.y.isFinite
        {
            let caretTopY = max(r.minY, r.maxY)
            origin = NSPoint(x: r.maxX + 2, y: caretTopY - size.height)
            _tpDebug("  -> positioned at \(origin) (caret rect: \(r))")
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
            _tpDebug("  -> no caret rect, using mouse pos \(mouse)")
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
