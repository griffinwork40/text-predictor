#!/usr/bin/env bash
# Build and launch TextPredictor (Debug). The binary must run from the
# Products dir so mlx-swift_Cmlx.bundle is colocated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

"$SCRIPT_DIR/build.sh" Debug
cd "$SCRIPT_DIR/xcode-build/Build/Products/Debug"
exec ./TextPredictor
