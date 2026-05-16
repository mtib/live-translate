#!/usr/bin/env bash
# Build LiveTranslate and wrap it into a proper .app bundle so macOS
# treats it as a real app (entitlements, menu bar, permissions prompts).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="LiveTranslate"
APP_DIR="build/${APP_NAME}.app"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Generate the app icon (idempotent — re-renders from the same SF Symbol
# every time) and drop the .icns into Resources/.
./tools/make-icon.sh build/icon
cp build/icon/icon.icns "${APP_DIR}/Contents/Resources/icon.icns"

# Ad-hoc sign so the TCC system will remember permission grants across runs.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo "✓ built ${APP_DIR}"
echo "  run with: open ${APP_DIR}"
