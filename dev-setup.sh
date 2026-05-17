#!/usr/bin/env bash
# Pre-download a set of GGML whisper models into the local `models/`
# directory so dev-side `./build.sh` can copy from there instead of
# re-fetching from Hugging Face every time you swap `WHISPER_MODEL`.
#
# Files are MIT-licensed (OpenAI Whisper weights, GGML repackaging by
# ggerganov). Re-running is cheap — existing files are kept.
#
# Usage:
#   ./dev-setup.sh                                    # download the default set
#   ./dev-setup.sh ggml-base-q5_1.bin ggml-tiny.bin  # download specific files
#
# `tools/build-whisper.sh` looks for `models/<name>.bin` first and falls
# back to downloading into `build/whisper-models/` if not present.
set -euo pipefail
cd "$(dirname "$0")"

DEST="models"
mkdir -p "${DEST}"

# Curated set for developer convenience. Order from smallest to
# largest so the download progresses visibly. Swap which one
# `WhisperCppTranscriber.bundledModelName` points at to test
# different quality/speed tradeoffs.
DEFAULT_MODELS=(
  ggml-tiny-q5_1.bin           # ~33 MB  — fastest, low quality
  ggml-base-q5_1.bin           # ~57 MB  — fast, marginal quality
  ggml-small-q5_1.bin          # ~190 MB — current bundled default
  ggml-large-v3-turbo-q5_0.bin # ~570 MB — best of the fast options
)

MODELS=("$@")
if [[ ${#MODELS[@]} -eq 0 ]]; then
  MODELS=("${DEFAULT_MODELS[@]}")
fi

for name in "${MODELS[@]}"; do
  dest="${DEST}/${name}"
  if [[ -s "${dest}" ]]; then
    echo "✓ already present: ${dest} ($(du -h "${dest}" | cut -f1))"
    continue
  fi
  url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${name}"
  echo "→ downloading ${name}"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "${dest}.partial" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -q -O "${dest}.partial" "${url}"
  else
    echo "✗ Neither curl nor wget available." >&2
    exit 1
  fi
  mv "${dest}.partial" "${dest}"
  echo "✓ saved ${dest} ($(du -h "${dest}" | cut -f1))"
done
echo
echo "✓ models ready in ${DEST}/"
echo "  set WHISPER_MODEL=<name> before ./build.sh to bundle a different one,"
echo "  and update WhisperCppTranscriber.bundledModelName to match."
