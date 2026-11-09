#!/usr/bin/env bash
# Turns a screen recording into a small, sharp GIF for the README.
# Record with ⌘⇧5 (Record Selected Portion), keep it 30–60 seconds, then run:
#
# Usage: scripts/make-demo-gif.sh <recording.mov> [out.gif] [width] [fps]
#   out.gif  defaults to docs/images/demo.gif
#   width    output width in pixels (default 960; GitHub shows READMEs ~880 px wide)
#   fps      frames per second (default 15; enough for hovers and slide-outs)
#
# Needs ffmpeg (brew install ffmpeg). Two passes: the first builds a palette from the
# whole clip so glass and gradients don't band, the second encodes with that palette.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

strInput="$1"
strOutput="${2:-docs/images/demo.gif}"
intWidth="${3:-960}"
intFps="${4:-15}"

if ! command -v ffmpeg >/dev/null; then
  echo "ffmpeg not found. Install it with: brew install ffmpeg" >&2
  exit 1
fi

strPalette="$(mktemp -t perchdock-palette).png"
trap 'rm -f "$strPalette"' EXIT

strFilters="fps=${intFps},scale=${intWidth}:-1:flags=lanczos"

# Pass 1: one palette tuned to what actually changes between frames.
ffmpeg -v error -y -i "$strInput" -vf "${strFilters},palettegen=stats_mode=diff" "$strPalette"

# Pass 2: encode, redrawing only the changed rectangle of each frame to keep the file small.
ffmpeg -v error -y -i "$strInput" -i "$strPalette" \
  -lavfi "${strFilters} [x]; [x][1:v] paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$strOutput"

intBytes=$(stat -f%z "$strOutput")
echo "Wrote $strOutput ($((intBytes / 1024)) KB)"
if (( intBytes > 10 * 1024 * 1024 )); then
  echo "Over 10 MB: GitHub may not render it inline. Try a lower width or fps, or a shorter clip." >&2
fi
