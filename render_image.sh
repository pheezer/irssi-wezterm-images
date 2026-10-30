#!/usr/bin/env bash
# Download an image URL, make a small / pixelated / faded thumbnail, and
# deliver "<thumb>\t<url>\t<width>" to the viewer pane via wezterm cli send-text.
#
# args: URL PANE_ID WIDTH COLORIZE_PCT SATURATION PIXEL_PCT MAX_MB
set -euo pipefail

url=${1:?url required}
pane=${2:?pane id required}
width=${3:-20}
colorize=${4:-20}
sat=${5:-55}
pix=${6:-20}
maxmb=${7:-10}

# clamp pixelate so the inverse upscale is well defined (avoids div-by-zero)
[ "$pix" -ge 1 ] 2>/dev/null || pix=20
[ "$pix" -le 100 ] 2>/dev/null || pix=100
up=$(( 10000 / pix ))        # inverse of pix%, e.g. 20 -> 500(%)

dir="${TMPDIR:-/tmp}/irssi-wezterm-img"
mkdir -p "$dir"
key=$(printf '%s' "$url" | md5)      # macOS: stdin md5 prints just the hash
src="$dir/$key.src"
out="$dir/$key.png"

# Reuse an already-rendered thumb (cheap dedupe across restarts).
if [ ! -f "$out" ]; then
  curl -sL --max-time 30 --connect-timeout 10 \
       --max-filesize $((maxmb * 1024 * 1024)) \
       -A 'Mozilla/5.0' -o "$src" "$url" || exit 0
  [ -s "$src" ] || exit 0

  # order matters: shrink -> pixelate (nearest-neighbour down then up) -> fade last.
  # [0] takes the first frame so animated GIFs produce a single still.
  magick "${src}[0]" \
         -resize '300x300>' \
         -filter point -scale "${pix}%" -scale "${up}%" \
         -modulate "100,${sat}" -fill white -colorize "${colorize}%" \
         "$out" || exit 0
  rm -f "$src"
fi

[ -s "$out" ] || exit 0
printf '%s\t%s\t%s\n' "$out" "$url" "$width" \
  | wezterm cli send-text --no-paste --pane-id "$pane"
