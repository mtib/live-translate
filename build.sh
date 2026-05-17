#!/usr/bin/env bash
# Build LiveTranslate and wrap it into a proper .app bundle so macOS
# treats it as a real app (entitlements, menu bar, permissions prompts).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="LiveTranslate"
APP_DIR="build/${APP_NAME}.app"

# Build whisper.cpp + download the GGML model up front. Idempotent —
# skipped on subsequent runs if both are already in place. Produces:
#   build/whisper-prefix/lib/lib{whisper,ggml,…}.a   (linked by SwiftPM)
#   build/whisper-prefix/include/*.h                 (mirrored into Sources/CWhisper/include)
#   build/whisper-models/ggml-base-q5_1.bin           (bundled into .app Resources)
./tools/build-whisper.sh

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Bundle the whisper.cpp GGML model into Resources. The transcriber
# looks here first (via Bundle.main.url(forResource:withExtension:))
# and falls back to ~/Documents/LiveTranslate/models/ for user
# overrides (drop a larger model file there if you want).
cp "build/whisper-models/ggml-large-v3-turbo-q5_0.bin" "${APP_DIR}/Contents/Resources/ggml-large-v3-turbo-q5_0.bin"

# Generate the app icon (idempotent — re-renders from the same SF Symbol
# every time) and drop the .icns into Resources/.
./tools/make-icon.sh build/icon
cp build/icon/icon.icns "${APP_DIR}/Contents/Resources/icon.icns"

# Ad-hoc sign so the TCC system will remember permission grants across runs.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo "✓ built ${APP_DIR}"
echo "  run with: open ${APP_DIR}"
