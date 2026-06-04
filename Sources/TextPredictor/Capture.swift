// Capture.swift — Accessibility read of the frontmost app's text field,
// plus synthesized typing for suggestion insertion.

import AppKit
import ApplicationServices

enum Capture {
    struct FocusContext {
        /// Text in the focused element before the current caret position.
        let beforeCaret: String
        /// Caret rect in AppKit screen coords (origin bottom-left). nil if
        /// AX couldn't resolve geometry (some Notes states don't expose it).
        let caretRect: CGRect?
        /// The AX element. Held by the session in case we want to refer back.
        let element: AXUIElement
        /// Caret location as a character index into the element's value.
        let caretLocation: Int
    }

    /// Returns a FocusContext if and only if a frontmost app is in the
    /// allowed set AND a text-input-shaped element is focused.
    static func notesFocusContext() -> FocusContext? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log.debug("No frontmost app")
            return nil
        }
        let bundleID = frontApp.bundleIdentifier ?? ""
        guard TextPredictorConfig.allowedApps.contains(bundleID) else {
            log.debug("Frontmost is \(bundleID), not in allowed apps")
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef else {
            log.debug("No focused UI element (err \(focusErr.rawValue))")
            return nil
        }
        let element = focusedRef as! AXUIElement

        // Role check — text-input-shaped only. Notes typically reports
        // "AXTextArea" for the body; we accept a few neighbors defensively.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
        guard textRoles.contains(role) else {
            log.debug("Focused element role is '\(role)' — not a text field")
            return nil
        }

        // Selected text range — gives us caret location.
        var rangeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        var caretLoc = 0
        if let rv = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) {
                caretLoc = cfRange.location
            }
        }

        // Full text value — for Notes the body element responds to kAXValue.
        // May come back as NSString or NSAttributedString.
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        var fullText = ""
        if let s = valueRef as? String {
            fullText = s
        } else if let attr = valueRef as? NSAttributedString {
            fullText = attr.string
        } else if valueRef != nil {
            log.debug("kAXValue returned unexpected type: \(String(describing: valueRef))")
        }

        let safeCaret = min(caretLoc, fullText.count)
        let beforeCaret = String(fullText.prefix(safeCaret))

        // Caret rect via parameterized AX attribute.
        let caretRect = caretRectForRange(
            element: element, location: safeCaret)

        return FocusContext(
            beforeCaret: beforeCaret,
            caretRect: caretRect,
            element: element,
            caretLocation: safeCaret
        )
    }

    /// Read the bounds rect for a zero-length range at `location`, converted
    /// to AppKit screen coords. Returns nil if AX can't resolve it.
    private static func caretRectForRange(element: AXUIElement, location: Int)
        -> CGRect?
    {
        var range = CFRange(location: location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return nil
        }
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard err == .success, let br = boundsRef else {
            log.debug("AXBoundsForRange unavailable (err \(err.rawValue))")
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(br as! AXValue, .cgRect, &rect) else {
            return nil
        }
        let screenRect = axRectToScreenRect(rect)
        log.debug(
            """
            Caret rect raw AX \(NSStringFromRect(rect), privacy: .public) \
            → AppKit \(NSStringFromRect(screenRect), privacy: .public)
            """
        )
        return screenRect
    }

    /// AX returns rects with origin TOP-LEFT of the main screen. AppKit uses
    /// BOTTOM-LEFT. Flip Y against the main screen's height.
    private static func axRectToScreenRect(_ ax: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return ax }
        return CGRect(
            x: ax.origin.x,
            y: main.frame.height - ax.origin.y - ax.size.height,
            width: ax.size.width,
            height: ax.size.height
        )
    }

    // MARK: - Synthesized typing for accept

    /// Type the given text into whatever has focus, via CGEvent unicode
    /// payload. Flows through the system's normal text input pathway, so
    /// undo, autocorrect, and rich-text formatting all behave naturally.
    static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log.error("Could not create CGEventSource for typeText")
            return
        }
        var utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        else {
            log.error("Could not create keyDown event")
            return
        }
        down.flags = []
        utf16.withUnsafeMutableBufferPointer { buf in
            down.keyboardSetUnicodeString(
                stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cgAnnotatedSessionEventTap)

        // Matching keyUp so the input system doesn't think the key is held.
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = []
            utf16.withUnsafeMutableBufferPointer { buf in
                up.keyboardSetUnicodeString(
                    stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
