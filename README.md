# irssi-wezterm-images

An [irssi](https://irssi.org/) script that automatically previews image URLs
posted in IRC as **small, pixelated, slightly-faded** thumbnails rendered in a
dedicated [WezTerm](https://wezfurlong.org/wezterm/) side pane, each with a
clickable link to open the original.

```
┌─────────────┬────────────┐
│ irssi chat  │ [img] faded│
│ <bob> look  │  pixelated │
│  cool.png   │ ⤢ open link│
│ <ann> nice  │ [img] ...  │
│             │ ⤢ open link│
└─────────────┴────────────┘
```

## Why a side pane instead of inline?

irssi is a full-screen ncurses app that owns the terminal and redraws it
constantly. Terminal image protocols (iTerm2/OSC-1337, Kitty, Sixel) draw at
the cursor position, so an image drawn *inside* irssi's chat buffer is erased
the moment irssi redraws or you scroll. That's why no mature "inline image"
irssi script exists.

Instead, this script spawns **one dedicated WezTerm pane** — a normal terminal
that irssi never touches — and renders thumbnails there. Images themselves
can't carry hyperlinks (terminals only hyperlink text), so each thumbnail gets
a clickable `⤢ open original` text link beneath it (OSC 8).

## How it works

```
 IRC msg ─▶ wezterm_img.pl  (irssi Perl script)
              │  signal "message public" / "message private"
              │  extract image URLs, dedupe
              │  ensure_viewer() → one reusable side pane (pane-id cached)
              │  fork() worker  (keeps irssi's event loop unblocked)
              ▼
         render_image.sh <url> <pane> <style…>
              │  curl → temp file
              │  magick: resize → nearest-neighbour pixelate → desaturate+fade
              │  wezterm cli send-text  "<thumb>\t<url>\t<width>"
              ▼
         viewer.sh  (runs inside the side pane)
              │  wezterm imgcat --width N --no-move-cursor <thumb>
              └  OSC 8 clickable "⤢ open original" → <url>
```

The fade is background-independent (desaturate + wash toward white) so it looks
right regardless of terminal theme.

## Requirements

- [WezTerm](https://wezfurlong.org/wezterm/) — the script only activates when
  `$WEZTERM_PANE` is set.
- `irssi` with Perl support (the default).
- `imagemagick` (provides `magick`).
- `curl` and `bash` (preinstalled on macOS).

```sh
brew install irssi imagemagick
```

## Install

Clone, then symlink the script into irssi's autorun directory so it loads on
startup. The script finds its helper shell scripts relative to its own real
location, so it works from wherever you clone it.

```sh
git clone <this-repo> ~/github/irssi-wezterm-images
mkdir -p ~/.irssi/scripts/autorun
ln -sf ~/github/irssi-wezterm-images/wezterm_img.pl ~/.irssi/scripts/wezterm_img.pl
ln -sf ../wezterm_img.pl ~/.irssi/scripts/autorun/wezterm_img.pl
```

Then launch `irssi` inside WezTerm. You should see:

```
>> wezterm_img loaded. WezTerm detected.
```

To load without restarting: `/script load wezterm_img.pl`

## Usage

Just chat. When someone posts an image URL (`.png .jpg .jpeg .gif .webp`), the
side pane appears (on first image) and the thumbnail renders. `Cmd`-click the
`⤢ open original` link to open the full image in your browser.

Test without waiting for a real URL:

```
/wezterm_img_test https://picsum.photos/400/300.jpg
```

Note: the message signals only fire once connected to a server (e.g.
`/connect irc.libera.chat`); `/wezterm_img_test` works offline.

## Settings

Change live with `/set <name> <value>`:

| Setting                     | Default | Meaning                                              |
|-----------------------------|---------|------------------------------------------------------|
| `wezterm_img_enabled`       | `ON`    | Master on/off switch.                                |
| `wezterm_img_width_cells`   | `20`    | Thumbnail width in terminal cells.                   |
| `wezterm_img_pane_percent`  | `35`    | Side pane width as % of the window.                  |
| `wezterm_img_colorize_pct`  | `20`    | Fade strength — % wash toward white.                 |
| `wezterm_img_saturation`    | `55`    | Color saturation (lower = more washed out).          |
| `wezterm_img_pixel_pct`     | `20`    | Pixelation — downscale %, then back up (lower = blockier). |
| `wezterm_img_max_mb`        | `10`    | Max download size; larger images are skipped.        |
| `wezterm_img_channels`      | *(all)* | Space-separated channels/nicks to limit to.          |
| `wezterm_img_helper_dir`    | *(auto)*| Where `render_image.sh` / `viewer.sh` live.          |

The defaults are a "medium" style — moderate fade, visible chunky pixels. For a
heavier/retro look: `/set wezterm_img_pixel_pct 12` and
`/set wezterm_img_colorize_pct 30`.

## Files

- `wezterm_img.pl` — the irssi script (signal hooks, settings, pane management).
- `render_image.sh` — download + ImageMagick transform + deliver to the pane.
- `viewer.sh` — runs inside the side pane; renders thumbnails and links.

## License

MIT — see [LICENSE](LICENSE).
