// App.swift — entry point, menu-bar item, permission onboarding, trigger flow.
//
// M1A scope: Ctrl+Space in any allowed app, inline ghost text, auto-debounce.
// No confidence gate, no event log, no per-app profiles, no settings UI beyond
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
    private var ghostText: GhostText!
    private var autoTrigger: AutoTrigger!
    private let inference = Inference()
    private var enabled: Bool =
        UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    private var activeSession: PredictionSession?
    private var keyDebounceItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("TextPredictor launching…")
        TextPredictorConfig.debugLog(">>> applicationDidFinishLaunching")
        ghostText = GhostText()
        setupStatusItem()
        promptPermissionsIfNeeded()
        installHotkeys()
        installAutoTrigger()

        // Warmup the model + JIT Metal kernels off the main thread so the
        // first real Ctrl+Space hits steady-state latency (~30 ms) instead of
        // cold-start (~550 ms).
        Task { [inference] in
            do {
                TextPredictorConfig.debugLog(">>> Starting warmup...")
                try await inference.warmup()
                TextPredictorConfig.debugLog(">>> Warmup complete")
                await MainActor.run { self.markReady() }
            } catch {
                TextPredictorConfig.debugLog(">>> Warmup FAILED: \(error.localizedDescription)")
                log.error("Warmup failed: \(error.localizedDescription)")
                await MainActor.run { self.statusItem.button?.title = "✨!" }
            }
        }
    }

    private func markReady() {
        statusItem.button?.title = "✨"
        TextPredictorConfig.debugLog(">>> markReady: status icon is now ✨")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✨…"  // loading
        statusItem.button?.toolTip = "TextPredictor — inline ghost text"

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
            onAnyOtherKey: { [weak self] in self?.handleOrdinaryKeypress() }
        )
        let installed = hotkeys.installIfPossible()
        TextPredictorConfig.debugLog("Hotkey tap installed: \(installed)")
        if !installed {
            log.warning("Could not install CGEventTap — Input Monitoring missing?")
        }
    }

    // MARK: - Trigger flow

    private func handleOrdinaryKeypress() {
        if ghostText.isActiveOrVisible {
            _ = dismissSuggestion()
        }

        keyDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            TextPredictorConfig.debugLog("KeyDebounce: expired — firing prediction")
            self.triggerPrediction()
        }
        keyDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.350, execute: item)
    }

    private func triggerPrediction() {
        TextPredictorConfig.debugLog(">>> triggerPrediction called")
        guard enabled else {
            log.debug("Trigger ignored: disabled")
            TextPredictorConfig.debugLog("  -> ignored: disabled")
            return
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              TextPredictorConfig.isAppAllowed(frontApp.bundleIdentifier ?? "")
        else {
            let app = NSWorkspace.shared.frontmostApplication
            log.debug("Trigger ignored: \(app?.bundleIdentifier ?? "no app") not in allowed apps")
            TextPredictorConfig.debugLog("  -> ignored: \(app?.bundleIdentifier ?? "no app") not in allowed")
            return
        }
        guard let context = Capture.notesFocusContext() else {
            log.debug("Trigger ignored: no focused text field")
            TextPredictorConfig.debugLog("  -> ignored: no focused text field (Capture.notesFocusContext() returned nil)")
            return
        }
        let trimmedBuffer = context.beforeCaret.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmedBuffer.count >= 3 else {
            log.debug("Trigger ignored: buffer too short (\(trimmedBuffer.count) chars)")
            TextPredictorConfig.debugLog("  -> ignored: buffer too short (\(trimmedBuffer.count) chars)")
            return
        }

        TextPredictorConfig.debugLog("  -> proceeding: buffer=\(trimmedBuffer.prefix(40))…")

        // Cancel any in-flight session before starting a new one.
        activeSession?.task.cancel()
        let session = PredictionSession(context: context)
        activeSession = session

        let prompt = context.beforeCaret
        log.debug("Trigger: \(prompt.suffix(40))…")

        session.task = Task { [weak self] in
            do {
                let raw = try await self?.inference.predict(prompt: prompt, maxTokens: 12) ?? ""
                if Task.isCancelled { return }
                let suggestion = Self.trimToWordLimit(Self.trimToFirstStop(raw), maxWords: 3)
                guard !suggestion.isEmpty else {
                    log.debug("Suggestion empty after trim")
                    return
                }
                await MainActor.run {
                    guard let self, self.activeSession === session else { return }
                    self.ghostText.show(
                        text: suggestion,
                        element: context.element,
                        caretRect: context.caretRect)
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
        // Insert via inline AX injection + synthesized typing — flows through
        // the target app's regular text input pathway and respects its undo stack.
        ghostText.accept(suggestion: suggestion)
        activeSession = nil
        log.info("Accepted: \(suggestion)")
        return true
    }

    @discardableResult
    private func dismissSuggestion() -> Bool {
        guard let session = activeSession else { return false }
        let wasVisible = ghostText.isActiveOrVisible
        ghostText.dismiss()
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

    static func trimToWordLimit(_ s: String, maxWords: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxWords > 0, !trimmed.isEmpty else { return "" }

        var words: [Substring] = []
        var end = trimmed.startIndex
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else { break }

            let wordStart = index
            while index < trimmed.endIndex, !trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }

            words.append(trimmed[wordStart..<index])
            end = index
            if words.count == maxWords { break }
        }

        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
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
