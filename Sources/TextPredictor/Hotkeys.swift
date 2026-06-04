// Hotkeys.swift — global CGEventTap that handles three special keystrokes:
//
//   Ctrl+Space  → always consume; fires onTrigger.
//   Tab         → consume IFF onAccept returns true (overlay was visible).
//   Esc         → consume IFF onDismiss returns true (overlay was visible).
//   Any other   → passes through; fires onAnyOtherKey so the overlay hides.
//
// The tap is installed on the main run loop, so its C callback runs on the
// main thread. `MainActor.assumeIsolated` lets the Swift 6 compiler trust
// that promise inside the C-conv callback.

import AppKit
@preconcurrency import CoreGraphics

@MainActor
final class Hotkeys {
    private let onTrigger: () -> Void
    private let onAccept: () -> Bool
    private let onDismiss: () -> Bool
    private let onAnyOtherKey: () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let kCtrlSpace: Int64 = 49  // kVK_Space
    private static let kTab: Int64 = 48        // kVK_Tab
    private static let kEsc: Int64 = 53        // kVK_Escape

    init(
        onTrigger: @escaping () -> Void,
        onAccept: @escaping () -> Bool,
        onDismiss: @escaping () -> Bool,
        onAnyOtherKey: @escaping () -> Void
    ) {
        self.onTrigger = onTrigger
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onAnyOtherKey = onAnyOtherKey
    }

    /// Returns true if the tap was installed. Returns false if creation
    /// failed (typically because Input Monitoring isn't granted yet).
    func installIfPossible() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let monitor = Unmanaged<Hotkeys>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    // Tap callback runs on the main run loop because we
                    // install it there in installIfPossible. Tell Swift 6.
                    return MainActor.assumeIsolated {
                        monitor.handle(type: type, event: event)
                    }
                },
                userInfo: selfPtr
            )
        else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS occasionally disables a tap (e.g. on system hiccup). Re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Ctrl+Space → trigger (consume).
        if keyCode == Self.kCtrlSpace && flags.contains(.maskControl) {
            onTrigger()
            return nil
        }

        // Tab alone → try to accept.
        let isPlainTab =
            keyCode == Self.kTab
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
        if isPlainTab {
            if onAccept() { return nil }
            return Unmanaged.passUnretained(event)
        }

        // Esc → try to dismiss.
        if keyCode == Self.kEsc {
            if onDismiss() { return nil }
            return Unmanaged.passUnretained(event)
        }

        // Any other key → also dismiss (if visible), but never consume.
        onAnyOtherKey()
        return Unmanaged.passUnretained(event)
    }
}
