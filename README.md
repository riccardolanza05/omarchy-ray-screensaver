# Ray Screensaver

An Omarchy shell plugin that ports the hero animation from
[plugins.omarchy.org](https://plugins.omarchy.org) into a real screensaver:
a cloud of round dots, drawn fresh every frame from a closed-form formula
`(i, t) → (x, y)`. Five scenes rotate through — **RAY**, **BIRD**, **WING**
(three of the site's own six), **WAVE** and **SPIRAL** (two more, in the
same spirit — see "Where the scenes come from" below) — one scene per
screensaver activation: it opens on the next scene in the rotation and
stays on it for as long as it's shown, however long that is. Dismiss it
(unlock, or any input) and the *next* activation moves one step further,
cycling through all five before repeating.

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

## Where the scenes come from

**RAY, BIRD, WING** are a 1:1 read of `setupHeroRay()` in the site's
`assets/js/app.js` — verified by fetching the file directly; it carries no
comments, credit, or link to a source of its own. It belongs to a genre of
compact, trigonometry-driven point-cloud sketches that circulates on X/Twitter
under the hashtag **#つぶやきProcessing** ("Tsubuyaki Processing" — sketches
that fit in a single tweet), most visibly through creators like
[@yuruyurau](https://x.com/yuruyurau). This plugin credits that lineage but
is not a copy of any single named sketch — like the site's own version, it's
an independent implementation of the same style of formula. Three of the
site's six original scenes (ORIGINAL, COCOON, STORM) are intentionally left
out — dropped by request in the desktop version this plugin is based on,
kept out here too for consistency.

**WAVE** (a grid rippled by two summed sine waves) and **SPIRAL** (a
phyllotaxis/Vogel spiral — the sunflower-seed-head pattern) are unrelated
formulas in the same single-colour-dot-cloud style, added later. Both are
classic, well-documented, public-domain patterns with no single sketch or
author to credit — see `paintWave()`/`paintSpiral()` in
`ScreensaverView.qml` for exactly what they compute.

Jump straight to any scene by index (0=RAY, 1=BIRD, 2=WING, 3=WAVE,
4=SPIRAL) without disturbing the rotation itself:

```sh
omarchy-shell ray-screensaver previewIndex 3   # WAVE, say
```

## Known limitations

- The rotation only persists for as long as `omarchy-shell` keeps running
  (`keepLoaded: true` keeps this plugin's state alive between idle cycles,
  but a full shell restart resets it) — it does not survive a logout/login
  the way the desktop-only prototype's on-disk state file did.
- No per-user tuning knobs yet (point count, zoom, which scenes are in the
  rotation) — everything is fixed at the values that looked right during
  development. Contributions welcome.

## License

MIT — see [LICENSE](./LICENSE).
