#!/usr/bin/env bash
# Preview a non-image link. If the page embeds a dominant image (og:image,
# twitter:image, or a first <img>), show THAT image via the normal image
# pipeline — this makes image-host / pastebin landing pages preview as the
# actual picture. Otherwise fall back to a webpage screenshot.
#
# Screenshots use shot-scraper (a Playwright/Chromium wrapper) rather than
# desktop Chrome, which hangs on scripted headless screenshots. Install once:
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
maxmb=${7:-10}

source "$(dirname "$0")/thumb_lib.sh"

# Resolve a relative/absolute image reference against the page URL's origin.
# Prints an absolute URL. Handles "http(s)://…", "//host/…", "/abs", "rel".
resolve_url() {
  local page=$1 ref=$2 origin scheme
  case "$ref" in
    http://*|https://*) printf '%s' "$ref"; return ;;
    //*)                scheme=${page%%://*}; printf '%s:%s' "$scheme" "$ref"; return ;;
  esac
  origin=$(printf '%s' "$page" | sed -E 's#^(https?://[^/]+).*#\1#')
  case "$ref" in
    /*) printf '%s%s' "$origin" "$ref" ;;
    *)  printf '%s/%s' "$origin" "$ref" ;;
  esac
}

# Fetch the page HTML and echo a candidate image URL, or nothing.
# Priority: og:image -> twitter:image -> first <img src>.
resolve_embedded_image() {
  local page=$1 html ref
  html=$(curl -sL --max-time 15 --connect-timeout 10 --max-filesize 2097152 \
              -A 'Mozilla/5.0' "$page" 2>/dev/null) || return 1
  [ -n "$html" ] || return 1

  for pat in 'og:image' 'twitter:image'; do
    ref=$(printf '%s' "$html" \
      | grep -ioE "<meta[^>]+(property|name)=[\"']?${pat}[\"']?[^>]*>" \
      | grep -ioE "content=[\"']?[^\"' >]+" | head -1 \
      | sed -E "s/content=[\"']?//")
    [ -n "$ref" ] && { resolve_url "$page" "$ref"; return 0; }
  done

  ref=$(printf '%s' "$html" \
    | grep -ioE "<img[^>]+src=[\"']?[^\"' >]+" | head -1 \
    | sed -E "s/.*src=[\"']?//")
  [ -n "$ref" ] && { resolve_url "$page" "$ref"; return 0; }

  return 1
}

# content-type looks like an image?
is_image_url() {
  curl -sIL --max-time 15 --connect-timeout 10 -A 'Mozilla/5.0' "$1" 2>/dev/null \
    | grep -iE '^content-type:[[:space:]]*image/' >/dev/null
}

# 1) Try to render an embedded image (shown with the PAGE url as the link).
img=$(resolve_embedded_image "$url" || true)
if [ -n "${img:-}" ] && is_image_url "$img"; then
  fetch_and_thumb "$img" "$url" "$pane" "$width" "$colorize" "$sat" "$pix" "$maxmb" \
    && exit 0
  # if that failed, fall through to a screenshot
fi

# 2) Fall back to a webpage screenshot.
SHOT=${WZT_SHOT:-}
if [ -z "$SHOT" ]; then
  for c in "$HOME/.local/bin/shot-scraper" shot-scraper; do
    command -v "$c" >/dev/null 2>&1 && { SHOT=$c; break; }
  done
fi
[ -n "$SHOT" ] || exit 0   # no engine installed; nothing more to try

dir="${TMPDIR:-/tmp}/irssi-wezterm-img"
mkdir -p "$dir"
key=$(printf '%s' "$url" | md5)
src="$dir/$key.shot.png"
out="$dir/$key.site.png"

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
