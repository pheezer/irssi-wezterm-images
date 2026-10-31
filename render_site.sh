#!/usr/bin/env bash
# Screenshot a webpage, make a small / pixelated / faded thumbnail, and deliver
# "<thumb>\t<page-url>\t<width>" to the viewer pane via wezterm cli send-text.
#
# Uses shot-scraper (a Playwright/Chromium wrapper) rather than desktop Chrome,
# which hangs on scripted headless screenshots on this machine. Install once:
#   uv tool install shot-scraper && shot-scraper install
#
# args: PAGE_URL PANE_ID WIDTH COLORIZE_PCT SATURATION PIXEL_PCT MAX_MB
set -uo pipefail

url=${1:?url required}
pane=${2:?pane id required}
width=${3:-20}
colorize=${4:-20}
sat=${5:-55}
pix=${6:-20}
# $7 (max_mb) accepted for arg-compatibility with render_image.sh; unused here.

source "$(dirname "$0")/thumb_lib.sh"

# Locate shot-scraper (not necessarily on PATH when launched from irssi).
SHOT=${WZT_SHOT:-}
if [ -z "$SHOT" ]; then
  for c in "$HOME/.local/bin/shot-scraper" shot-scraper; do
    command -v "$c" >/dev/null 2>&1 && { SHOT=$c; break; }
  done
fi
[ -n "$SHOT" ] || exit 0   # no engine installed; render nothing

dir="${TMPDIR:-/tmp}/irssi-wezterm-img"
mkdir -p "$dir"
key=$(printf '%s' "$url" | md5)
src="$dir/$key.shot.png"
out="$dir/$key.site.png"

# Reuse an already-rendered thumb (cheap dedupe across restarts).
if [ ! -f "$out" ]; then
  # --silent keeps stdout clean; above-the-fold 1280x900; short settle wait.
  timeout 45 "$SHOT" "$url" -o "$src" \
      --width 1280 --height 900 --wait 1200 --silent >/dev/null 2>&1 || exit 0
  [ -s "$src" ] || exit 0

  make_thumb "$src" "$out" "$width" "$colorize" "$sat" "$pix" || exit 0
  rm -f "$src"
fi

[ -s "$out" ] || exit 0
printf '%s\t%s\t%s\n' "$out" "$url" "$width" \
  | wezterm cli send-text --no-paste --pane-id "$pane"
