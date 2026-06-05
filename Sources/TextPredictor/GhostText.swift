// GhostText.swift — Inline Copilot-style ghost text, injected into the target
// app's AX element via `kAXSuggestedValuesAttribute`.
//
// The suggestion is shown inline with the user's typed text, scrolls with
// scrolling, and Tab/Enter commits it at the current cursor position.
// Falls back to the floating panel if the element doesn't support it.
//
// Threading model: called from the main actor (AutoTrigger callback and
// hotkey path converge here via `triggerPrediction()`).

import AppKit
import OSLog

private let ghostLog = Logger(subsystem: "com.local.text-predictor", category: "ghosttext")
private let kSuggestedValuesAttr = "AXSuggestedValues"

@MainActor
final class GhostText {
    /// The AX element that the suggestion was injected into (nil = inactive).
    private var textElement: AXUIElement?
    /// Original field value, saved at show time so we can restore on dismiss.
    private var savedOriginalValue: String?
    /// True while a suggestion is active.
    private(set) var isActive = false

    private var floatingPanel: Overlay?

    // MARK: - Show

    /// Inject suggestion inline. The caller must pass the focused element
    /// so we can write `kAXSuggestedValuesAttribute` on it.
    func show(text: String, element: AXUIElement) {
        // If we already have a pending suggestion for this element, update it.
        if isActive, textElement == element {
            _ = _setInlineSuggestion(text, on: element)
            return
        }

        textElement = element
        isActive = true
        // Save the current field value so we can restore on dismiss.
        savedOriginalValue = _readFieldString(element)

        // Try inline injection first.
        let injected = _setInlineSuggestion(text, on: element)
        if !injected {
            // Fall back to floating panel (existing behavior).
            floatingPanel = Overlay()
            floatingPanel?.show(text: text, near: nil)
        }

        ghostLog.debug("GhostText: suggestion shown (inline=\(injected))")
    }

    // MARK: - Accept

    /// Type the suggestion text at the current caret position (synthesized
    /// keyboard events). Does NOT clear the element value — the user's text
    /// stays intact and the suggestion is simply inserted.
    func accept(suggestion: String) {
        _clear()
        // The user's caret is already at the right position (their typing
        // just brought us here). Synthesize typing the suggestion.
        Capture.typeText(suggestion)
        ghostLog.info("GhostText: accepted: \(suggestion)")
    }

    // MARK: - Dismiss

    /// Dismiss without accepting. Restores the element's original value
    /// if the field was replaced by inline injection.
    func dismiss() {
        restoreOriginalValue()
        _clear()
    }

    // MARK: - Visibility

    var isActiveOrVisible: Bool {
        isActive || (floatingPanel?.isVisible ?? false)
    }

    // MARK: - Internal

    /// Try to set `kAXSuggestedValuesAttribute` on the element.
    /// Returns true if the call succeeded (the app may or may not render it).
    private func _setInlineSuggestion(_ text: String, on element: AXUIElement) -> Bool {
        let value: [String] = [text]
        let err = AXUIElementSetAttributeValue(
            element, kSuggestedValuesAttr as CFString, value as CFTypeRef)
        if err == .success {
            return true
        }
        // Some apps (or older macOS) may not support this attribute.
        // We still mark it "injected = false" so the caller falls back.
        ghostLog.debug("GhostText: AXSuggestedValues failed (err \(err.rawValue))")
        return false
    }

    /// Read the text value of an AX element as a plain string.
    private func _readFieldString(_ element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef)
        guard err == .success else { return nil }
        if let s = valueRef as? String { return s }
        if let attr = valueRef as? NSAttributedString { return attr.string }
        return nil
    }

    /// Restore the field's value to what it was before the suggestion was shown.
    private func restoreOriginalValue() {
        guard let element = textElement, let original = savedOriginalValue else {
            return
        }
        // Some apps ignore setAttribute for AXValue. If that happens, the
        // suggestion text just stays in the field — the user can backspace
        // through it or dismiss and start fresh.
        _ = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, original as CFTypeRef)
        textElement = nil
        savedOriginalValue = nil
        isActive = false
        ghostLog.debug("GhostText: restored original value")
    }

    /// Clear all state (inline + floating panel).
    private func _clear() {
        textElement = nil
        savedOriginalValue = nil
        isActive = false

        if let panel = floatingPanel {
            panel.hide()
            floatingPanel = nil
        }
        ghostLog.debug("GhostText: cleared")
    }
}
