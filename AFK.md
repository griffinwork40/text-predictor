# TextPredictor — M1A

System-wide macOS text predictor (all apps, inline ghost text). A vertical-slice spike proving the M1 pipeline end-to-end: **AX read → inline injection → MLX inference → Tab accept**.

## Commands

```bash
./build.sh           # Debug build (default)
./build.sh Release   # Release build (faster steady-state)
./run.sh             # Build + launch (Debug)
```

The binary lands at `xcode-build/Build/Products/{Debug,Release}/TextPredictor`. Always launch from that directory so the colocated `mlx-swift_Cmlx.bundle` is found at runtime.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 26+ with Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- Qwen3-1.7B-4bit weights cached at `~/.cache/huggingface/hub/models--mlx-community--Qwen3-1.7B-4bit/`

## Architecture

```
Package.swift                    — SwiftPM manifest (Swift 6.1, MLX + HuggingFace deps)
Sources/TextPredictor/
  App.swift         — @main entry, status item, permissions, trigger/accept/dismiss flow
  Capture.swift     — AX focus reader (text + caret rect + location) + synthesized typing
  Hotkeys.swift     — CGEventTap: Ctrl+Space trigger, Tab accept, Esc dismiss
  GhostText.swift   — inline AX injection via kAXSuggestedValuesAttribute (M1A)
  Inference.swift   — mlx-swift-lm wrapper (Qwen3-1.7B-4bit) + LogprobCapture (M1B)
  Config.swift      — allowedApps allowlist (default: all apps)
  AutoTrigger.swift — AX-observer-based always-on auto-debounce (M1A)
build.sh              — xcodebuild wrapper (Debug/Release)
run.sh                — build + launch convenience
```

### Key subsystems

- **AX (Accessibility)**: Reads the frontmost app's focused text element (text value, caret position, caret rect). Only activates for apps in `TextPredictorConfig.allowedApps` (default: all).
- **Hotkeys**: Session-wide `CGEventTap` intercepts Ctrl+Space (trigger), Tab (accept), Esc (dismiss). Other keys dismiss the overlay.
- **Inference**: In-process `mlx-swift-lm` with Qwen3-1.7B-4bit. Warms up at launch (model load + JIT Metal kernels). Supports cancellation mid-flight.
- **GhostText**: Inline suggestion injected via `kAXSuggestedValuesAttribute` on
  the focused text element. Falls back to a floating panel if the attribute
  isn't supported.
- **AutoTrigger** (M1A): AX observer watches for value changes in text-shaped
  elements, fires a 350ms-debounced prediction callback.

## Conventions

- **Swift 6 strict concurrency**: `@MainActor` on UI classes, `actor Inference` for MLX work. C callbacks use `MainActor.assumeIsolated` (callback runs on main run loop).
- **No confidence gate in M1A**: `LogprobCapture` is wired but unused — M1B will gate rendering on it.
- **Deterministic sampling**: `ArgMaxSampler` (no temperature) for M1A.
- **Session model**: `PredictionSession` tracks in-flight context; new Ctrl+Space cancels prior task.
- **Accept via synthesized typing**: `CGEvent.keyboardSetUnicodeString` flows through Notes' normal input path (preserves undo, autocorrect, rich text).
- **M1A scope**: All apps (configurable via `TextPredictorConfig.allowedApps`), inline ghost text (Copilot-style), auto-debounce (350ms), manual Ctrl+Space trigger, no settings UI, no `.app` bundle.
