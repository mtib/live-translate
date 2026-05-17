#!/usr/bin/env python3
"""Merge two LiveTranslate per-source SRTs into a single per-language SRT.

LiveTranslate writes one SRT per (input stream, language) pair:

    transcripts/<stamp>.mic.de.srt
    transcripts/<stamp>.system.de.srt
    transcripts/<stamp>.mic.en.srt
    transcripts/<stamp>.system.en.srt

For playback with a single subtitle track per language, merge the two
streams for one language into one file. Cues are time-sorted; mic and
system cues are distinguished by a leading "[Mic] " / "[Sys] " prefix.

Usage:
    tools/merge-srt.py <mic.srt> <system.srt> <output.srt>
    tools/merge-srt.py ~/Documents/LiveTranslate/transcripts/2026-05-17_13-46-19.mic.de.srt \\
                       ~/Documents/LiveTranslate/transcripts/2026-05-17_13-46-19.system.de.srt \\
                       ~/Documents/LiveTranslate/transcripts/2026-05-17_13-46-19.de.srt

Cue overlaps are kept as-is (both shown simultaneously). SRT players
handle overlapping cues by stacking them.
"""
import re
import sys
from pathlib import Path


# Matches one SRT cue block: index, "HH:MM:SS,mmm --> HH:MM:SS,mmm",
# one or more text lines, then a blank-line terminator (or EOF).
CUE_RE = re.compile(
    r"(\d+)\s*\n"
    r"(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})\s*\n"
    r"((?:.+\n?)+?)"
    r"(?:\n|\Z)",
    re.MULTILINE,
)


def parse_timestamp(s: str) -> float:
    """Parse 'HH:MM:SS,mmm' → seconds (float)."""
    hms, ms = s.split(",")
    h, m, sec = map(int, hms.split(":"))
    return h * 3600 + m * 60 + sec + int(ms) / 1000.0


def format_timestamp(seconds: float) -> str:
    """Inverse of parse_timestamp."""
    total = max(0.0, seconds)
    h = int(total // 3600)
    m = int((total % 3600) // 60)
    s = int(total % 60)
    ms = int(round((total - int(total)) * 1000))
    if ms == 1000:  # rounding rollover
        ms = 0
        s += 1
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def load_cues(path: Path, label: str) -> list[tuple[float, float, str]]:
    """Return list of (start_sec, end_sec, "[Label] text") tuples."""
    if not path.exists():
        return []
    raw = path.read_text(encoding="utf-8")
    out = []
    for m in CUE_RE.finditer(raw):
        start = parse_timestamp(m.group(2))
        end = parse_timestamp(m.group(3))
        text = m.group(4).rstrip()
        out.append((start, end, f"[{label}] {text}"))
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    mic_path, sys_path, out_path = (Path(p) for p in argv[1:])
    cues = (
        load_cues(mic_path, "Mic")
        + load_cues(sys_path, "Sys")
    )
    if not cues:
        print(f"merge-srt: no cues in {mic_path} or {sys_path}", file=sys.stderr)
        return 1
    cues.sort(key=lambda c: c[0])
    with out_path.open("w", encoding="utf-8") as f:
        for i, (start, end, text) in enumerate(cues, start=1):
            f.write(f"{i}\n{format_timestamp(start)} --> {format_timestamp(end)}\n{text}\n\n")
    print(f"merge-srt: wrote {len(cues)} cues → {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
