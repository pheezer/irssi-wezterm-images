# Shared thumbnail step for render_image.sh and render_site.sh.
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
