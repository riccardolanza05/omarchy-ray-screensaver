# Ray Screensaver

An Omarchy shell plugin that ports the hero animation from
[plugins.omarchy.org](https://plugins.omarchy.org) into a real screensaver:
a parametric cloud of round dots, drawn fresh every frame from a single
closed-form formula `(i, t) → (x, y)`. Three of the site's own six scenes are
included — **RAY**, **BIRD**, **WING** — cycling one step further each time
the screensaver shows, and once more every 14 seconds while it stays up.

Every dot is drawn in **your current Omarchy theme's foreground colour**, on
your theme's background — no accent, no extra tint, just one colour that
matches whatever theme you're running. Switch theme (including an automatic
day/night switch) and the screensaver picks it up live.

## Why a plugin, not just a script

The formula itself is trivial to port to anything that can draw — the point
of packaging it as an Omarchy shell plugin is that **the colour-matching
comes for free for anyone who installs it**: it reads the same
`Color.foreground` / `Color.background` that every other part of the Omarchy
shell (bar, lock screen, menus) already uses, so it looks native to whatever
theme you're on without you touching a single setting.

## Install

```sh
omarchy plugin add https://github.com/riccardolanza05/omarchy-ray-screensaver --enable
```

This plugin **clones Omarchy's stock idle service** (`omarchy.idle`) rather
than sitting alongside it — same pattern used by
[lock-explorer](https://github.com/sirjul1337/lock-explorer) for
`omarchy.lock`. It handles idle → screensaver → lock exactly like the stock
service (same timeouts, same stay-awake behaviour), the only difference
being *what's shown* at the screensaver timeout. Installing it disables
`omarchy.idle`; if you later remove this plugin, re-enable the stock one
with `omarchy plugin enable omarchy.idle`.

## Try it without waiting for idle

```sh
omarchy-shell ray-screensaver preview   # show it now
omarchy-shell ray-screensaver status    # what it's doing
omarchy-shell ray-screensaver disable   # hide it / pause idle handling
omarchy-shell ray-screensaver enable    # resume
```

## Trying other animation styles

Two experimental scenes outside the setupHeroRay formula live in `Presets.js`
(index 3 and 4) — a grid rippled by two summed sine waves (the classic
three.js "particles waves" demo pattern) and a phyllotaxis/Vogel spiral (the
sunflower-seed-head pattern), both public-domain math rather than a copy of
any one person's sketch. They're not part of the RAY→BIRD→WING rotation —
try them without disturbing it:

```sh
omarchy-shell ray-screensaver previewIndex 3   # WAVE
omarchy-shell ray-screensaver previewIndex 4   # SPIRAL
```

## What this is (and isn't) a port of

The formula is a 1:1 read of `setupHeroRay()` in the site's
`assets/js/app.js` — verified by fetching the file directly; it carries no
comments, credit, or link to a source of its own. It belongs to a genre of
compact, trigonometry-driven point-cloud sketches that circulates on X/Twitter
under the hashtag **#つぶやきProcessing** ("Tsubuyaki Processing" — sketches
that fit in a single tweet), most visibly through creators like
[@yuruyurau](https://x.com/yuruyurau). This plugin credits that lineage but
is not a copy of any single named sketch — like the site's own version, it's
an independent implementation of the same style of formula.

Three of the six original scenes (ORIGINAL, COCOON, STORM) are intentionally
left out here — dropped by request in the desktop version this plugin is
based on, kept out here too for consistency.

## Known limitations

- The RAY→BIRD→WING rotation only persists for as long as `omarchy-shell`
  keeps running (`keepLoaded: true` keeps this plugin's state alive between
  idle cycles, but a full shell restart resets it) — it does not survive a
  logout/login the way the desktop-only prototype's on-disk state file did.
- No per-user tuning knobs yet (point count, zoom, hold duration) —
  everything is fixed at the values that looked right during
  development. Contributions welcome.

## License

MIT — see [LICENSE](./LICENSE).
