# Shared helpers for render_image.sh and render_site.sh.

# make_thumb <src> <out> <width> <colorize_pct> <saturation> <pixel_pct>
# Produces a small / pixelated / faded PNG at <out>. Returns non-zero on failure.
make_thumb() {
  local src=$1 out=$2 width=$3 colorize=$4 sat=$5 pix=$6

  # clamp pixelate so the inverse upscale is well defined (avoids div-by-zero)
  [ "$pix" -ge 1 ] 2>/dev/null || pix=20
  [ "$pix" -le 100 ] 2>/dev/null || pix=100
  local up=$(( 10000 / pix ))        # inverse of pix%, e.g. 20 -> 500(%)

  # order matters: shrink -> pixelate (nearest-neighbour down then up) -> fade last.
  # [0] takes the first frame so animated GIFs produce a single still.
  magick "${src}[0]" \
         -resize '300x300>' \
         -filter point -scale "${pix}%" -scale "${up}%" \
         -modulate "100,${sat}" -fill white -colorize "${colorize}%" \
         "$out"
}

# Download an image, thumbnail it, and deliver it to the viewer pane.
#   fetch_and_thumb <img_url> <link_url> <pane> <width> <colorize> <sat> <pix> <maxmb>
# <img_url>  is what gets downloaded; <link_url> is shown as "open original"
# (they differ when the image was resolved from a landing page). The thumb is
# cached by md5(img_url). Returns 0 on successful delivery, non-zero otherwise.
fetch_and_thumb() {
  local img_url=$1 link_url=$2 pane=$3 width=$4 colorize=$5 sat=$6 pix=$7 maxmb=$8

  local dir="${TMPDIR:-/tmp}/irssi-wezterm-img"
  mkdir -p "$dir"
  local key src out
  key=$(printf '%s' "$img_url" | md5)
  src="$dir/$key.src"
  out="$dir/$key.png"

  # Reuse an already-rendered thumb (cheap dedupe across restarts).
  if [ ! -f "$out" ]; then
    curl -sL --max-time 30 --connect-timeout 10 \
         --max-filesize $(( maxmb * 1024 * 1024 )) \
         -A 'Mozilla/5.0' -o "$src" "$img_url" || return 1
    [ -s "$src" ] || return 1
    make_thumb "$src" "$out" "$width" "$colorize" "$sat" "$pix" || return 1
    rm -f "$src"
  fi

  [ -s "$out" ] || return 1
  printf '%s\t%s\t%s\n' "$out" "$link_url" "$width" \
    | wezterm cli send-text --no-paste --pane-id "$pane"
}
