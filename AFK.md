# TextPredictor — M1A

System-wide macOS text predictor (Apple Notes only). A vertical-slice spike proving the M1 pipeline end-to-end: **AX read → MLX inference → ghost-text overlay → Tab accept**.

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
  Overlay.swift     — borderless NSPanel ghost-text renderer (45% opacity, SF Pro 15pt)
  Inference.swift   — mlx-swift-lm wrapper (Qwen3-1.7B-4bit) + LogprobCapture (M1B)
  AutoTrigger.swift — AX-observer-based always-on auto-trigger (M1B feature)
build.sh              — xcodebuild wrapper (Debug/Release)
run.sh                — build + launch convenience
```

### Key subsystems

- **AX (Accessibility)**: Reads Notes' focused text element (text value, caret position, caret rect). Only activates inside `com.apple.Notes`.
- **Hotkeys**: Session-wide `CGEventTap` intercepts Ctrl+Space (trigger), Tab (accept), Esc (dismiss). Other keys dismiss the overlay.
- **Inference**: In-process `mlx-swift-lm` with Qwen3-1.7B-4bit. Warms up at launch (model load + JIT Metal kernels). Supports cancellation mid-flight.
- **Overlay**: Borderless, click-through `NSPanel` positioned at the caret rect. 45% opacity, single-line, no wrapping.
- **AutoTrigger** (M1B): AX observer watches for value changes in text-shaped elements, fires a 350ms-debounced prediction callback.

## Conventions

- **Swift 6 strict concurrency**: `@MainActor` on UI classes, `actor Inference` for MLX work. C callbacks use `MainActor.assumeIsolated` (callback runs on main run loop).
- **No confidence gate in M1A**: `LogprobCapture` is wired but unused — M1B will gate rendering on it.
- **Deterministic sampling**: `ArgMaxSampler` (no temperature) for M1A.
- **Session model**: `PredictionSession` tracks in-flight context; new Ctrl+Space cancels prior task.
- **Accept via synthesized typing**: `CGEvent.keyboardSetUnicodeString` flows through Notes' normal input path (preserves undo, autocorrect, rich text).
- **M1A scope**: Apple Notes only, manual Ctrl+Space trigger, no settings UI, no `.app` bundle.
