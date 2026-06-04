// AutoTrigger.swift — AX-observer-based always-on auto-trigger.
//
// Watches the frontmost app for value changes in text-shaped elements and fires
// a debounced prediction callback. Ctrl+Space (Hotkeys.swift) is unchanged
// and works as a manual override alongside this path.
//
// Threading model: all public methods and the AX observer callback are
// guaranteed to run on the main actor. CF observer callbacks arrive on the
// run loop we add the observer source to (main run loop), so
// `MainActor.assumeIsolated` is used in the C trampoline — matching the
// pattern in Hotkeys.swift.

import AppKit
import ApplicationServices
import OSLog

private let autoLog = Logger(subsystem: "com.local.text-predictor", category: "autotrigger")

/// Debounce window in seconds. Increase if predictions fire too eagerly on
/// slow typists; decrease for snappier feel. Do NOT make it < 100 ms or you
/// will saturate inference on held keys.
private let kDebounceSecs: TimeInterval = 0.350

// MARK: - AutoTrigger

@MainActor
final class AutoTrigger {

    // Callback into AppDelegate — kept as a closure so this file has no
    // import or reference to AppDelegate (testable in isolation).
    private let onFire: () -> Void

    // AX observer for the frontmost app.
    private var axObserver: AXObserver?
    // The app-level AX element the focus-changed notification is on.
    private var notesAppElement: AXUIElement?
    // The text element currently observed for value-changed notifications.
    private var observedTextElement: AXUIElement?
    // Pending debounce work item. Replaced on every value-changed event.
    private var debounceItem: DispatchWorkItem?

    private var isEnabled: Bool = true

    // Workspace notification tokens.
    private var activateToken: NSObjectProtocol?
    private var deactivateToken: NSObjectProtocol?

    // MARK: - Init / deinit

    init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        subscribeWorkspaceNotifications()
        // If a text-capable app is already frontmost at launch, install immediately.
        if let front = NSWorkspace.shared.frontmostApplication,
           TextPredictorConfig.allowedApps.contains(front.bundleIdentifier ?? "")
        {
            installObserver(for: front)
        }
    }

    // MARK: - Enabled gate

    /// Called from AppDelegate.toggleEnabled(_:). Tears down observers when
    /// disabled so we avoid unnecessary AX wakeups.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            tearDownObserver()
            autoLog.debug("AutoTrigger disabled — observer torn down")
        } else {
            // Re-install if a text-capable app is currently frontmost.
            if let front = NSWorkspace.shared.frontmostApplication,
               TextPredictorConfig.allowedApps.contains(front.bundleIdentifier ?? "")
            {
                installObserver(for: front)
                autoLog.debug("AutoTrigger re-enabled — observer reinstalled")
            }
        }
    }

    // MARK: - Workspace notifications

    private func subscribeWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        activateToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract app before crossing into MainActor.assumeIsolated so
            // Swift 6 doesn't see the Notification value crossing actor bounds.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard let self, let app, TextPredictorConfig.allowedApps.contains(app.bundleIdentifier ?? "") else { return }
            MainActor.assumeIsolated {
                guard self.isEnabled else { return }
                self.installObserver(for: app)
            }
        }

        deactivateToken = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard let self, let app, TextPredictorConfig.allowedApps.contains(app.bundleIdentifier ?? "") else { return }
            MainActor.assumeIsolated {
                self.tearDownObserver()
                autoLog.debug("AutoTrigger: app deactivated — observer detached")
            }
        }
    }

    // MARK: - Observer install / teardown

    private func installObserver(for app: NSRunningApplication) {
        // If we already have an observer for the same PID, do nothing.
        if let el = notesAppElement {
            var installedPid: pid_t = 0
            AXUIElementGetPid(el, &installedPid)
            if installedPid == app.processIdentifier {
                autoLog.debug("AutoTrigger: observer already installed for pid \(installedPid)")
                return
            }
        }

        tearDownObserver()  // clean up any stale observer

        let pid = app.processIdentifier
        var observer: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let obs = observer else {
            autoLog.error("AutoTrigger: AXObserverCreate failed (err \(err.rawValue)) — AX permission missing?")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let addErr = AXObserverAddNotification(
            obs, appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            selfPtr)
        guard addErr == .success else {
            autoLog.error("AutoTrigger: could not observe focus-changed (err \(addErr.rawValue))")
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .commonModes)

        axObserver = obs
        notesAppElement = appElement
        autoLog.debug("AutoTrigger: observer installed for pid \(pid)")
    }

    private func tearDownObserver() {
        cancelDebounce()
        detachValueChangedObserver()

        guard let obs = axObserver else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .commonModes)
        if let el = notesAppElement {
            AXObserverRemoveNotification(
                obs, el,
                kAXFocusedUIElementChangedNotification as CFString)
        }
        axObserver = nil
        notesAppElement = nil
        autoLog.debug("AutoTrigger: observer torn down")
    }

    // MARK: - Value-changed observer attachment

    private func attachValueChangedObserver(to element: AXUIElement) {
        guard let obs = axObserver else { return }
        // Detach from any prior element first (idempotent).
        detachValueChangedObserver()

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(
            obs, element,
            kAXValueChangedNotification as CFString,
            selfPtr)
        guard addErr == .success else {
            autoLog.debug("AutoTrigger: could not attach value-changed (err \(addErr.rawValue))")
            return
        }
        observedTextElement = element
        autoLog.debug("AutoTrigger: value-changed observer attached to text element")
    }

    private func detachValueChangedObserver() {
        guard let obs = axObserver, let el = observedTextElement else { return }
        AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
        observedTextElement = nil
        autoLog.debug("AutoTrigger: value-changed observer detached")
    }

    // MARK: - Notification dispatch (called from C trampoline)

    // `element` and `notifStr` originate from the AX callback which runs on
    // the main run loop — no cross-thread movement occurs.
    fileprivate func handleNotification(element: AXUIElement, notifStr: String) {
        if notifStr == kAXFocusedUIElementChangedNotification {
            handleFocusChanged(element: element)
            return
        }
        if notifStr == kAXValueChangedNotification {
            handleValueChanged()
            return
        }
    }

    private func handleFocusChanged(element: AXUIElement) {
        // Read the actual focused element from the notification's element
        // (which is the app element for focus-changed). Query the focused child.
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else {
            detachValueChangedObserver()
            return
        }
        let focusedEl = focused as! AXUIElement

        // Role check — only attach to text-shaped elements.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedEl, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

        if textRoles.contains(role) {
            attachValueChangedObserver(to: focusedEl)
        } else {
            detachValueChangedObserver()
            autoLog.debug("AutoTrigger: focus landed on '\(role)' — not a text element")
        }
    }

    private func handleValueChanged() {
        cancelDebounce()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                autoLog.debug("AutoTrigger: debounce expired — firing prediction")
                self.onFire()
            }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + kDebounceSecs, execute: item)
    }

    private func cancelDebounce() {
        debounceItem?.cancel()
        debounceItem = nil
    }
}

// MARK: - C trampoline

/// AXObserver callback. Runs on the main run loop (we add the observer source
/// to `CFRunLoopGetMain()`), so `MainActor.assumeIsolated` is valid here —
/// same pattern as Hotkeys.swift.
///
/// `AXUIElement` and `CFString` are not `Sendable` in Swift 6, but they are
/// not moving across threads here — the callback executes on the main run loop.
/// We convert `notification` to a plain `String` (Sendable) before the
/// `assumeIsolated` boundary, and wrap `element` in `nonisolated(unsafe)` to
/// assert to the compiler that no cross-thread access occurs.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData else { return }
    let trigger = Unmanaged<AutoTrigger>.fromOpaque(userData).takeUnretainedValue()
    // Convert CFString → String (Sendable) before crossing into assumeIsolated.
    let notifStr: String = notification as String
    // AXUIElement is a CF type with no Sendable conformance. Wrap it so the
    // Swift 6 checker doesn't flag it — we are already on the main run loop.
    nonisolated(unsafe) let el: AXUIElement = element
    MainActor.assumeIsolated {
        trigger.handleNotification(element: el, notifStr: notifStr)
    }
}
