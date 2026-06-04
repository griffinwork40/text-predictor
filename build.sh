#!/usr/bin/env bash
# Build TextPredictor via xcodebuild. swift build cannot compile mlx-swift's
# Metal shaders; xcodebuild can.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-Debug}"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild \
    -scheme TextPredictor \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath ./xcode-build \
    -skipMacroValidation \
    build

echo
echo "Build complete. Run:"
echo "  cd xcode-build/Build/Products/$CONFIG && ./TextPredictor"
