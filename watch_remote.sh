#!/usr/bin/env bash
# Local bridge for running irssi REMOTELY (ssh/mosh) while previewing images
# LOCALLY in WezTerm.
#
# Run this ON YOUR MAC, inside WezTerm, where the remote irssi has
# `/set wezterm_img_mode remote`. It streams the remote queue file over plain
# SSH and renders each image URL into a local WezTerm side pane. All download
# + ImageMagick + wezterm work happens locally, so the remote host needs only
# irssi + this project's wezterm_img.pl (no imagemagick/wezterm required there).
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
#   WZT_PANE_PERCENT=35
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
render="$here/render_image.sh"
viewer="$here/viewer.sh"

width=${WZT_WIDTH:-20}
colorize=${WZT_COLORIZE:-20}
sat=${WZT_SAT:-55}
pix=${WZT_PIX:-20}
maxmb=${WZT_MAXMB:-10}
percent=${WZT_PANE_PERCENT:-35}

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
  PANE=$(wezterm cli split-pane --right --percent "$percent" \
           --pane-id "$host_pane" -- bash "$viewer" "$width" 2>/dev/null)
  PANE=${PANE//[^0-9]/}
  [ -n "$PANE" ] || { echo "warn: could not spawn viewer pane" >&2; return 1; }
  wezterm cli activate-pane --pane-id "$host_pane" >/dev/null 2>&1   # keep focus here
  return 0
}

echo "watching $target:$remote_queue → local WezTerm pane (Ctrl-C to stop)"
ensure_pane || exit 1

# -n0: only new lines; -F: follow across truncation/recreation (plugin may be
# reloaded). stderr silenced so the "waiting for file" notice isn't noise.
remote_cmd="tail -n0 -F \"$remote_queue\" 2>/dev/null"

while true; do
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    ensure_pane || continue
    bash "$render" "$url" "$PANE" "$width" "$colorize" "$sat" "$pix" "$maxmb" \
      || echo "warn: render failed for $url" >&2
  done < <(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
               -o ConnectTimeout=10 ${WZT_SSH_OPTS:-} "$target" "$remote_cmd")
  echo "ssh stream ended; reconnecting in 3s…" >&2
  sleep 3
done
