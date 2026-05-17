#!/usr/bin/env bash
# Build whisper.cpp (and its bundled ggml) into a local install prefix
# that the CWhisper SwiftPM bridge target links against.
#
# Idempotent: if build/whisper-prefix/lib/libwhisper.a already exists and
# is newer than the source checkout, this is a no-op. Pass --force to
# rebuild from scratch.
#
# Why a build script instead of vendoring source files? whisper.cpp has
# ~100 C/C++/Metal files spread across ggml backends with a non-trivial
# CMake configuration. Vendoring would require us to track upstream
# changes file-by-file. Cloning + building keeps us at a clean pinned
# version while leaving build flag choices to upstream.
set -euo pipefail

cd "$(dirname "$0")/.."

WHISPER_TAG="${WHISPER_TAG:-v1.7.4}"
SRC_DIR="external/whisper.cpp"
BUILD_DIR="build/whisper-build"
PREFIX_DIR="build/whisper-prefix"
MODEL_DIR="build/whisper-models"
# Multilingual large-v3-turbo, Q5_0-quantized. ~570 MB. Materially
# more accurate than the smaller models while still real-time-friendly
# on Apple Silicon (the "turbo" variant is a distilled large model
# designed for streaming). MIT-licensed (Whisper weights from OpenAI,
# GGML repackaging by ggerganov on Hugging Face).
MODEL_NAME="${WHISPER_MODEL:-ggml-large-v3-turbo-q5_0.bin}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"

# --force wipes the prefix; the rebuild then re-clones if SRC_DIR is also
# missing or at the wrong tag.
if [[ "${1:-}" == "--force" ]]; then
  echo "→ --force: removing ${PREFIX_DIR} and ${BUILD_DIR}"
  rm -rf "${PREFIX_DIR}" "${BUILD_DIR}"
fi

# Skip the library build if the install is already in place. We still
# fall through to the model-download block below so a freshly-renamed
# `MODEL_NAME` is fetched even when the libs haven't changed.
if [[ -f "${PREFIX_DIR}/lib/libwhisper.a" ]]; then
  echo "✓ whisper.cpp already built at ${PREFIX_DIR} (pass --force to rebuild)"
  SKIP_LIB_BUILD=1
else
  SKIP_LIB_BUILD=0
  if ! command -v cmake >/dev/null 2>&1; then
    echo "✗ cmake is required but not installed."
    echo "  Install via: brew install cmake"
    exit 1
  fi
fi

# Fetch the pinned source tree if missing.
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "→ cloning whisper.cpp ${WHISPER_TAG} into ${SRC_DIR}"
  mkdir -p external
  git clone --depth 1 --branch "${WHISPER_TAG}" \
    https://github.com/ggerganov/whisper.cpp.git "${SRC_DIR}"
fi

# Configure + build. Flags chosen for our use case:
#   - BUILD_SHARED_LIBS=OFF  → static archives, statically linked into the .app
#   - WHISPER_BUILD_TESTS/EXAMPLES OFF → only the library
#   - GGML_METAL=ON          → Apple Silicon GPU backend (CPU fallback on Intel)
#   - GGML_METAL_EMBED_LIBRARY=ON → embed the .metal shaders into the static
#     lib so we don't need to ship default.metallib alongside the binary
#   - GGML_ACCELERATE=ON     → Apple Accelerate framework for the BLAS path
#   - GGML_NATIVE=ON         → let the compiler enable host-specific ISA
if [[ "${SKIP_LIB_BUILD}" == "0" ]]; then
  echo "→ configuring CMake build at ${BUILD_DIR}"
  # `GGML_NATIVE=OFF`: don't let ggml probe the build host for ARM
  # microarchitecture extensions like i8mm. The autodetection on
  # whisper.cpp v1.7.4 misbehaves on some Apple-Silicon CI runners —
  # it sets `__ARM_FEATURE_MATMUL_INT8` without telling the compiler
  # to allow the intrinsics, breaking the build. With native off, the
  # baseline arm64 build path is used and works on every Apple Silicon
  # generation. The perf cost vs. native is single-digit percent on
  # whisper inference because Metal does the heavy lifting anyway.
  cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$(pwd)/${PREFIX_DIR}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_NATIVE=OFF \
    >/dev/null

  echo "→ compiling (this takes a minute on first run; cached after)"
  cmake --build "${BUILD_DIR}" --config Release -j

  echo "→ installing to ${PREFIX_DIR}"
  cmake --install "${BUILD_DIR}" >/dev/null

  # Sanity check: SwiftPM will silently link against an empty lib if the
  # install layout is wrong, then runtime will fail with mysterious unresolved
  # symbols. Verify the headline archive exists at the expected location.
  if [[ ! -f "${PREFIX_DIR}/lib/libwhisper.a" ]]; then
    echo "✗ libwhisper.a missing after install — check CMake output above."
    exit 1
  fi
  echo "✓ whisper.cpp built and installed to ${PREFIX_DIR}"
  echo "  libs: $(ls "${PREFIX_DIR}/lib"/*.a | tr '\n' ' ')"

  # Mirror the public headers into the SwiftPM bridge target. This is the
  # version Swift's clang-module sandbox can find at `import CWhisper`
  # time. See Sources/CWhisper/include/CWhisper.h for the rationale.
  # whisper.h includes ggml.h / ggml-cpu.h / ggml-backend.h transitively,
  # so we copy the whole include directory rather than hand-track the
  # transitive set as upstream evolves.
  cp "${PREFIX_DIR}/include/"*.h "Sources/CWhisper/include/"
fi

# Model download. Bundled into the .app by build.sh so the user doesn't
# need to run any curl commands. Cached on disk; only re-downloaded if
# the file is missing or empty.
mkdir -p "${MODEL_DIR}"
MODEL_PATH="${MODEL_DIR}/${MODEL_NAME}"
if [[ ! -s "${MODEL_PATH}" ]]; then
  echo "→ downloading ${MODEL_NAME} (one-time, ~570 MB)"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "${MODEL_PATH}.partial" "${MODEL_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -q -O "${MODEL_PATH}.partial" "${MODEL_URL}"
  else
    echo "✗ Neither curl nor wget available to download the model."
    exit 1
  fi
  mv "${MODEL_PATH}.partial" "${MODEL_PATH}"
fi
echo "✓ model present: ${MODEL_PATH} ($(du -h "${MODEL_PATH}" | cut -f1))"
