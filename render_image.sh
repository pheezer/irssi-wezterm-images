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

source "$(dirname "$0")/thumb_lib.sh"

fetch_and_thumb "$url" "$url" "$pane" "$width" "$colorize" "$sat" "$pix" "$maxmb" || exit 0
