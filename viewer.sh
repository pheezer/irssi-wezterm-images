#!/usr/bin/env bash
# Runs inside the dedicated WezTerm side pane. Reads lines of
# "<thumb-path>\t<original-url>\t<width-cells>" on stdin and, for each,
# renders the thumbnail followed by a clickable (OSC 8) "open original" link.
default_width="${1:-20}"

# Lines are delivered via `wezterm cli send-text`, which the TTY would echo
# back above each image. Suppress that so only the thumbnails + links show.
stty -echo 2>/dev/null
trap 'stty echo 2>/dev/null' EXIT

printf '\033[2J\033[H'            # clear pane
printf '\033[2m— image previews —\033[0m\n\n'

while IFS=$'\t' read -r thumb url width; do
  [ -n "$thumb" ] && [ -f "$thumb" ] || continue
  [ -n "$width" ] || width="$default_width"
  wezterm imgcat --width "$width" --no-move-cursor "$thumb" 2>/dev/null || true
  # OSC 8 hyperlink: ESC ] 8 ;; URL ESC \  TEXT  ESC ] 8 ;; ESC \
  printf '\n\033]8;;%s\033\\\342\244\242 open original\033]8;;\033\\\n\n' "$url"
done
