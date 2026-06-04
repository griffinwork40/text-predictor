// App.swift — entry point, menu-bar item, permission onboarding, trigger flow.
//
// M1A scope: Ctrl+Space inside Apple Notes only. Manual trigger. No
// confidence gate, no event log, no per-app profiles, no settings UI beyond
// the menu-bar Enable/Disable + Quit.

import AppKit
import ApplicationServices
import IOKit.hid
import OSLog

let log = Logger(subsystem: "com.local.text-predictor", category: "app")

@main
struct TextPredictorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeys: Hotkeys!
    private var overlay: Overlay!
    private var autoTrigger: AutoTrigger!
    private let inference = Inference()
    private var enabled: Bool =
        UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    private var activeSession: PredictionSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("TextPredictor launching…")
        overlay = Overlay()
        setupStatusItem()
        promptPermissionsIfNeeded()
        installHotkeys()
        installAutoTrigger()

        // Warmup the model + JIT Metal kernels off the main thread so the
        // first real Ctrl+Space hits steady-state latency (~30 ms) instead of
        // cold-start (~550 ms).
        Task { [inference] in
            do {
                try await inference.warmup()
                await MainActor.run { self.markReady() }
            } catch {
                log.error("Warmup failed: \(error.localizedDescription)")
                await MainActor.run { self.statusItem.button?.title = "✨!" }
            }
        }
    }

    private func markReady() {
        statusItem.button?.title = "✨"
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✨…"  // loading
        statusItem.button?.toolTip = "TextPredictor — Ctrl+Space in Notes"

        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: enabled ? "Disable" : "Enable",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let permissions = NSMenuItem(
            title: "Recheck Permissions…",
            action: #selector(recheckPermissions(_:)),
            keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(
                title: "Quit TextPredictor",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "enabled")
        sender.title = enabled ? "Disable" : "Enable"
        if !enabled { _ = dismissSuggestion() }
        autoTrigger.setEnabled(enabled)
        log.info("Enabled = \(self.enabled)")
    }

    @objc private func recheckPermissions(_ sender: NSMenuItem) {
        promptPermissionsIfNeeded()
    }

    // MARK: - Permissions

    private func promptPermissionsIfNeeded() {
        let axGranted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        let imGranted =
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

        log.info("Permissions: AX=\(axGranted) InputMonitoring=\(imGranted)")

        guard !axGranted || !imGranted else { return }

        if !axGranted {
            // This call shows the system dialog the first time the binary
            // requests AX. Subsequent calls just check.
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        let alert = NSAlert()
        alert.messageText = "TextPredictor needs permissions"
        alert.informativeText = """
            Accessibility:    \(axGranted ? "granted ✓" : "MISSING")
            Input Monitoring: \(imGranted ? "granted ✓" : "MISSING")

            Both are required. Open System Settings → Privacy & Security, \
            grant both, then quit and relaunch this app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let target: String
            if !axGranted {
                target =
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            } else {
                target =
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
            if let url = URL(string: target) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Auto-trigger wiring

    private func installAutoTrigger() {
        autoTrigger = AutoTrigger(onFire: { [weak self] in
            self?.triggerPrediction()
        })
    }

    // MARK: - Hotkeys wiring

    private func installHotkeys() {
        hotkeys = Hotkeys(
            onTrigger: { [weak self] in self?.triggerPrediction() },
            onAccept: { [weak self] in self?.acceptSuggestion() ?? false },
            onDismiss: { [weak self] in self?.dismissSuggestion() ?? false },
            onAnyOtherKey: { [weak self] in _ = self?.dismissSuggestion() }
        )
        let installed = hotkeys.installIfPossible()
        if !installed {
            log.warning("Could not install CGEventTap — Input Monitoring missing?")
        }
    }

    // MARK: - Trigger flow

    private func triggerPrediction() {
        guard enabled else {
            log.debug("Trigger ignored: disabled")
            return
        }
        guard let context = Capture.notesFocusContext() else {
            log.debug("Trigger ignored: not in Notes or no focused text field")
            return
        }
        let trimmedBuffer = context.beforeCaret.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmedBuffer.count >= 3 else {
            log.debug("Trigger ignored: buffer too short (\(trimmedBuffer.count) chars)")
            return
        }

        // Cancel any in-flight session before starting a new one.
        activeSession?.task.cancel()
        let session = PredictionSession(context: context)
        activeSession = session

        let prompt = context.beforeCaret
        log.debug("Trigger: \(prompt.suffix(40))…")

        session.task = Task { [weak self] in
            do {
                let raw = try await self?.inference.predict(prompt: prompt, maxTokens: 16) ?? ""
                if Task.isCancelled { return }
                let suggestion = Self.trimToFirstStop(raw)
                guard !suggestion.isEmpty else {
                    log.debug("Suggestion empty after trim")
                    return
                }
                await MainActor.run {
                    guard let self, self.activeSession === session else { return }
                    self.overlay.show(text: suggestion, near: context.caretRect)
                    session.suggestion = suggestion
                    log.debug("Showed: \(suggestion)")
                }
            } catch is CancellationError {
                // expected
            } catch {
                log.error("Inference error: \(error.localizedDescription)")
            }
        }
    }

    private func acceptSuggestion() -> Bool {
        guard let session = activeSession, let suggestion = session.suggestion else {
            return false
        }
        overlay.hide()
        activeSession = nil
        // Insert via synthesized typing — flows through Notes' regular text
        // input pathway and respects its undo stack.
        Capture.typeText(suggestion)
        log.info("Accepted: \(suggestion)")
        return true
    }

    @discardableResult
    private func dismissSuggestion() -> Bool {
        guard let session = activeSession else { return false }
        let wasVisible = overlay.isVisible
        overlay.hide()
        session.task.cancel()
        activeSession = nil
        return wasVisible
    }

    // MARK: - Helpers

    static func trimToFirstStop(_ s: String) -> String {
        let stops: Set<Character> = [".", "?", "!", "\n"]
        var out = ""
        for ch in s {
            if stops.contains(ch) {
                out.append(ch)
                break
            }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PredictionSession {
    let context: Capture.FocusContext
    var task: Task<Void, Never> = Task {}
    var suggestion: String?

    init(context: Capture.FocusContext) {
        self.context = context
    }
}
