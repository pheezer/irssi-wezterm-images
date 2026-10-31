#!/usr/bin/env bash
# Local bridge for running irssi REMOTELY (ssh/mosh) while previewing images
# LOCALLY in WezTerm.
#
# Run this ON YOUR MAC, inside WezTerm, where the remote irssi has
# `/set wezterm_img_mode remote`. It streams the remote queue file over plain
# SSH and renders each item into a local WezTerm side pane. All download /
# screenshot + ImageMagick + wezterm work happens locally, so the remote host
# needs only irssi + this project's wezterm_img.pl.
#
# Each queue line is "TYPE<TAB>URL" where TYPE is img | site | close.
# A bare line with no tab is treated as img (back-compat).
#
# Usage:
#   watch_remote.sh <ssh-target> [remote-queue-path]
#
#   <ssh-target>        anything ssh accepts, ideally a ~/.ssh/config Host alias
#                       (so user/port/key are handled), e.g. `myserver`.
#   remote-queue-path   default: .irssi-wezterm-img.queue (relative to remote $HOME,
#                       matching the plugin's default). Override if you changed
#                       wezterm_img_queue_file on the remote.
#
# Style (match or tweak the look) via env vars:
#   WZT_WIDTH=20 WZT_COLORIZE=20 WZT_SAT=55 WZT_PIX=20 WZT_MAXMB=10
#   WZT_PANE_BUFFER=3   (pane width = WZT_WIDTH + WZT_PANE_BUFFER cells)
set -uo pipefail

target=${1:-}
if [ -z "$target" ]; then
  echo "usage: $0 <ssh-target> [remote-queue-path]" >&2
  exit 2
fi
remote_queue=${2:-.irssi-wezterm-img.queue}

if [ -z "${WEZTERM_PANE:-}" ]; then
  echo "error: not inside WezTerm (WEZTERM_PANE unset). Run this in a local WezTerm pane." >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
render_img="$here/render_image.sh"
render_site="$here/render_site.sh"
viewer="$here/viewer.sh"

width=${WZT_WIDTH:-20}
colorize=${WZT_COLORIZE:-20}
sat=${WZT_SAT:-55}
pix=${WZT_PIX:-20}
maxmb=${WZT_MAXMB:-10}
buffer=${WZT_PANE_BUFFER:-3}
cells=$(( width + buffer ))

host_pane=$WEZTERM_PANE
PANE=""

# 0 = present, 1 = genuinely absent, 2 = couldn't tell (list failed/empty).
# Treating "couldn't tell" as absent causes spurious respawns under the brief
# races around split-pane / send-text, so callers must distinguish it.
pane_status() {
  [ -n "$PANE" ] || return 1
  local json
  json=$(wezterm cli list --format json 2>/dev/null) || return 2
  [ -n "$json" ] || return 2
  grep -q "\"pane_id\": *$PANE\b" <<<"$json" && return 0
  return 1
}

ensure_pane() {
  pane_status
  case $? in
    0) return 0 ;;   # alive
    2) return 0 ;;   # unknown — keep the pane we have rather than respawn
  esac               # 1 => really gone, fall through and (re)spawn
  PANE=$(wezterm cli split-pane --right --cells "$cells" \
           --pane-id "$host_pane" -- bash "$viewer" "$width" 2>/dev/null)
  PANE=${PANE//[^0-9]/}
  [ -n "$PANE" ] || { echo "warn: could not spawn viewer pane" >&2; return 1; }
  wezterm cli activate-pane --pane-id "$host_pane" >/dev/null 2>&1   # keep focus here
  return 0
}

# Close our preview pane when the watcher exits (e.g. the thehoppening alias
# kills us when the mosh session ends).
cleanup() { [ -n "${PANE:-}" ] && wezterm cli kill-pane --pane-id "$PANE" >/dev/null 2>&1; }
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

echo "watching $target:$remote_queue → local WezTerm pane (Ctrl-C to stop)"
# Pane is created lazily on the first image (the per-URL loop calls ensure_pane),
# so launching this from a shell alias doesn't pop a blank pane every session.

# -n0: only new lines; -F: follow across truncation/recreation (plugin may be
# reloaded). stderr silenced so the "waiting for file" notice isn't noise.
remote_cmd="tail -n0 -F \"$remote_queue\" 2>/dev/null"

close_pane() {
  [ -n "$PANE" ] && wezterm cli kill-pane --pane-id "$PANE" >/dev/null 2>&1
  PANE=""
}

while true; do
  while IFS=$'\t' read -r type url; do
    # A bare line (no tab) parses as type=<url>, url=empty → treat as img.
    if [ -z "$url" ]; then url=$type; type=img; fi
    [ -n "$url" ] || continue
    case "$type" in
      close) close_pane; continue ;;
      site)  render=$render_site ;;
      *)     render=$render_img ;;
    esac
    ensure_pane || continue
    bash "$render" "$url" "$PANE" "$width" "$colorize" "$sat" "$pix" "$maxmb" \
      || echo "warn: render failed for $url" >&2
  done < <(ssh -n -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
               -o ConnectTimeout=10 ${WZT_SSH_OPTS:-} "$target" "$remote_cmd")
  echo "ssh stream ended; reconnecting in 3s…" >&2
  sleep 3
done
