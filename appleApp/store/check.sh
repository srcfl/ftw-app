#!/usr/bin/env bash
# Fails when a store text breaks one of Apple's limits for App Store Connect.
# Run it after editing anything in this folder.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import pathlib, sys

# file: (limit, unit). Keywords and review notes count bytes; the rest count
# characters.
limits = {
    "name.txt": (30, "chars"),
    "subtitle.txt": (30, "chars"),
    "promotional-text.txt": (170, "chars"),
    "description.txt": (4000, "chars"),
    "keywords.txt": (100, "bytes"),
    "release-notes.txt": (4000, "chars"),
    "review-notes.txt": (4000, "bytes"),
}
bad = 0
for path in sorted(pathlib.Path(".").rglob("*.txt")):
    text = path.read_text(encoding="utf-8").rstrip("\n")
    if path.name.endswith("-url.txt"):
        ok = text.startswith("https://") and "\n" not in text
        print(f"{'ok ' if ok else 'BAD'} {path}  {text}")
        bad += not ok
        continue
    if path.name not in limits:
        print(f"BAD {path}  not a field this script knows")
        bad += 1
        continue
    limit, unit = limits[path.name]
    size = len(text.encode()) if unit == "bytes" else len(text)
    ok = 0 < size <= limit
    if path.name == "keywords.txt":
        words = text.split(",")
        short = [w for w in words if len(w.strip()) <= 2]
        if short:
            ok = False
            print(f"    {path}: every keyword needs three or more characters: {short}")
    print(f"{'ok ' if ok else 'BAD'} {path}  {size}/{limit} {unit}")
    bad += not ok
sys.exit(1 if bad else 0)
PY
