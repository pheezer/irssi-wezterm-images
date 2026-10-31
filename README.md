# irssi-wezterm-images

An [irssi](https://irssi.org/) script that automatically previews links posted
in IRC as **small, pixelated, slightly-faded** thumbnails in a dedicated
[WezTerm](https://wezfurlong.org/wezterm/) side pane, each with a clickable link
to open the original. Image URLs are downloaded directly; non-image webpage
links are rendered to a screenshot (via [shot-scraper](https://shot-scraper.datasette.io/)).

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
- **For webpage previews only:** [shot-scraper](https://shot-scraper.datasette.io/)
  (a Playwright/Chromium screenshotter). Optional — without it, image previews
  still work and webpage links are simply skipped. Desktop Chrome is *not* used;
  it proved unreliable for scripted headless screenshots.

```sh
brew install irssi imagemagick
uv tool install shot-scraper && shot-scraper install   # optional, for webpage previews
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
>> wezterm_img 0.3 loaded. mode=local — rendering previews in a WezTerm side pane.
>> webpage previews on (/set wezterm_img_sites); /wezterm_img_close dismisses the pane.
```

To load without restarting: `/script load wezterm_img.pl`

## Usage

Just chat. When someone posts an **image URL** (`.png .jpg .jpeg .gif .webp`)
the side pane appears (on the first link) and the thumbnail renders. When
someone posts a **webpage link**, it's screenshotted and thumbnailed the same
way. `Cmd`-click the `⤢ open original` link to open the original in your
browser. The pane is sized to the thumbnail width plus a small buffer.

Commands:

```
/wezterm_img_test <image-or-webpage-url>   # preview a URL without waiting for one
/wezterm_img_close                         # dismiss the side pane
```

Note: the message signals only fire once connected to a server (e.g.
`/connect irc.libera.chat`); `/wezterm_img_test` works offline. Webpage
previews can be turned off with `/set wezterm_img_sites off`.

## Settings

Change live with `/set <name> <value>`:

| Setting                     | Default | Meaning                                              |
|-----------------------------|---------|------------------------------------------------------|
| `wezterm_img_enabled`       | `ON`    | Master on/off switch.                                |
| `wezterm_img_sites`         | `ON`    | Preview non-image webpage links (needs shot-scraper).|
| `wezterm_img_width_cells`   | `20`    | Thumbnail width in terminal cells.                   |
| `wezterm_img_pane_buffer`   | `3`     | Extra cells added to the pane beyond the thumbnail.  |
| `wezterm_img_colorize_pct`  | `20`    | Fade strength — % wash toward white.                 |
| `wezterm_img_saturation`    | `55`    | Color saturation (lower = more washed out).          |
| `wezterm_img_pixel_pct`     | `20`    | Pixelation — downscale %, then back up (lower = blockier). |
| `wezterm_img_max_mb`        | `10`    | Max download size; larger images are skipped.        |
| `wezterm_img_channels`      | *(all)* | Space-separated channels/nicks to limit to.          |
| `wezterm_img_helper_dir`    | *(auto)*| Where the `render_*.sh` / `viewer.sh` helpers live.  |
| `wezterm_img_mode`          | `auto`  | `auto`/`local`/`remote`/`off` — see Running remotely. |
| `wezterm_img_queue_file`    | *(auto)*| Remote mode: file preview items are appended to.     |

The defaults are a "medium" style — moderate fade, visible chunky pixels. For a
heavier/retro look: `/set wezterm_img_pixel_pct 12` and
`/set wezterm_img_colorize_pct 30`.

## Running irssi remotely (ssh / mosh / tmux)

By default (`wezterm_img_mode auto`) the script activates only when it sees
`$WEZTERM_PANE`. When you run irssi on a **remote** host over ssh/mosh, that
variable isn't set there, and the host can't reach your local WezTerm anyway:
`wezterm cli` talks to a unix socket on your Mac, and mosh does not forward
image escape sequences. So the preview can't be produced remotely.

Instead, split detection (remote) from rendering (local) with a small bridge:

1. **On the remote host**, in irssi: `/set wezterm_img_mode remote`. The script
   now just appends detected links to a queue file (`~/.irssi-wezterm-img.queue`
   by default; change with `wezterm_img_queue_file`), one `TYPE<TAB>URL` line
   per item. The remote host needs **only irssi + this `wezterm_img.pl`** — no
   imagemagick, no wezterm, no shot-scraper.

2. **On your Mac**, in a local WezTerm pane, run the watcher:

   ```sh
   ~/github/irssi-wezterm-images/watch_remote.sh <ssh-target> [remote-queue-path]
   ```

   where `<ssh-target>` is anything `ssh` accepts (ideally a `~/.ssh/config`
   Host alias so user/port/key are handled). It streams the remote queue over a
   plain SSH connection (auto-reconnecting) and renders each item into a local
   WezTerm side pane — all download / screenshot + ImageMagick + wezterm work
   happens locally. `/wezterm_img_close` on the remote tears the pane down here.
   Keep using mosh for the irssi session itself.

   Style is controlled by env vars (defaults match the medium look):
   `WZT_WIDTH WZT_COLORIZE WZT_SAT WZT_PIX WZT_MAXMB WZT_PANE_BUFFER`, plus
   `WZT_SSH_OPTS` for extra ssh flags.

`mode=local` forces local rendering even without `$WEZTERM_PANE`; `mode=off`
disables entirely. The load banner prints the resolved mode so you can tell at
a glance what it will do.

## Files

- `wezterm_img.pl` — the irssi script (signal hooks, settings, pane management).
- `render_image.sh` — download an image + thumbnail + deliver to the pane.
- `render_site.sh` — screenshot a webpage (shot-scraper) + thumbnail + deliver.
- `thumb_lib.sh` — shared `make_thumb` step (resize → pixelate → fade).
- `viewer.sh` — runs inside the side pane; renders thumbnails and links.
- `watch_remote.sh` — local bridge for remote irssi; streams the remote queue
  over SSH and renders previews in a local WezTerm pane.

## License

MIT — see [LICENSE](LICENSE).
