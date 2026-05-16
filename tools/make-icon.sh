#!/usr/bin/env bash
# Generate LiveTranslate's app icon as a .icns suitable for dropping into
# the .app bundle's Contents/Resources/. Driven from tools/make-icon.swift
# (which renders the master 1024×1024 PNG); we use `sips` + `iconutil` for
# the rest — both ship with macOS, no extra deps.
#
# Output paths:
#   build/icon/icon.iconset/        ← intermediate PNGs at all sizes
#   build/icon/icon.icns            ← final .icns
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-build/icon}"
ICONSET="${OUT_DIR}/icon.iconset"
ICNS="${OUT_DIR}/icon.icns"

mkdir -p "${ICONSET}"

# Render the 1024×1024 master (which doubles as the @2x of 512).
MASTER="${ICONSET}/icon_512x512@2x.png"
swift tools/make-icon.swift "${MASTER}"

# `iconutil` requires all of these specific filenames in the .iconset dir.
for spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png"
do
    px="${spec%%:*}"
    name="${spec##*:}"
    sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${ICNS}"
echo "✓ ${ICNS}"
