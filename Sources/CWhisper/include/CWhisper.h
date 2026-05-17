// Bridge header for the CWhisper SwiftPM target.
//
// The sibling `whisper.h` here is **not** checked into git — it is
// copied in from `build/whisper-prefix/include/whisper.h` by
// `tools/build-whisper.sh` (and re-copied on each rebuild so we don't
// drift from the actual built library).
//
// Why this dance? SwiftPM's clang-module sandbox strips `..` from
// `headerSearchPath` and applies `cSettings` only to the target's own
// source files (not the headers seen at module-import time). Putting a
// local copy of the public header alongside the bridge is the simplest
// way to make `import CWhisper` work from Swift.
#ifndef CWHISPER_BRIDGE_H
#define CWHISPER_BRIDGE_H

#include "whisper.h"

#endif
