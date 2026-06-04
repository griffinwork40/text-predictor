# TextPredictor — M1A

System-wide macOS text predictor (Apple Notes only, manual trigger).

Vertical-slice spike that proves the M1 pipeline end-to-end:
**AX read → MLX inference → ghost-text overlay → Tab accept**.

## Requirements

- macOS 14+
- Apple Silicon
- Xcode 26+ with Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain` once)
- Qwen3-1.7B-4bit weights cached at
  `~/.cache/huggingface/hub/models--mlx-community--Qwen3-1.7B-4bit/`

## Build

```bash
./build.sh           # Debug (default)
./build.sh Release   # Release (faster steady-state)
```

The binary lands at `xcode-build/Build/Products/{Debug,Release}/TextPredictor`.

The `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` next to it
is the Metal kernel payload. **Always launch from that directory** so the
bundle is found at runtime.

## Run

```bash
./run.sh
```

On first launch:
1. App appears in the menu bar (✨…, then ✨ once warmed up).
2. macOS prompts for **Accessibility** — grant in System Settings.
3. macOS prompts for **Input Monitoring** on first Ctrl+Space — grant, then
   quit (menu bar → Quit) and re-launch.

## Use

In Apple Notes only:

- Type some text.
- Press **Ctrl+Space** to request a continuation.
- Ghost text appears next to the caret.
- **Tab** inserts the suggestion.
- **Esc** dismisses.
- Typing anything else dismisses.

Outside Notes: nothing happens. By design.

## What works in M1A

- Menu bar item with Enable/Disable + Recheck Permissions + Quit.
- AX permission prompt and Input Monitoring detection.
- AX read of Notes' focused text area (text + caret rect + caret location).
- Ctrl+Space hotkey via session-wide `CGEventTap`.
- Qwen3-1.7B-4bit inference via in-process mlx-swift (warmed at launch).
- LogprobCapture wired but unused (M1B will gate on it).
- Borderless NSPanel ghost text at 45% opacity, baseline-aligned to caret.
- Tab synthesizes Unicode keystrokes to insert the suggestion through
  Notes' normal text-input pathway (preserves undo, autocorrect, etc.).
- Esc and any other key dismiss the overlay.
- Cancellation: a new Ctrl+Space mid-flight cancels the prior inference task.

## What is intentionally NOT in M1A

- No automatic / debounce-pause trigger (M1B).
- No confidence gate or band-based suppression (M1B).
- No partial accept — Tab takes the whole suggestion (M1C).
- No per-app profiles or blocklist (M1D).
- No event log (M1E).
- No retrieval, no LoRA, no summon panel, no settings UI.
- No `.app` bundle wrapping. The binary runs from the build products dir,
  which means menu-bar resident apps work, but launching the binary from
  Finder won't find the metallib. Use `./run.sh` or
  `cd …/Debug && ./TextPredictor`.

## Files

```
Package.swift
Sources/TextPredictor/
  App.swift         — entry, status item, permission flow, trigger flow
  Capture.swift     — AX focus reader + CGEvent text insertion
  Hotkeys.swift     — CGEventTap handling Ctrl+Space / Tab / Esc / others
  Overlay.swift     — NSPanel ghost-text renderer
  Inference.swift   — mlx-swift-lm wrapper + LogprobCapture
build.sh
run.sh
```
