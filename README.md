# Drift

A minimalist particle-animation screensaver for Omarchy — a cloud of round
dots that drifts and folds into shifting shapes, always drawn in your
**current Omarchy theme's own colours**.

![Drift preview](preview.png)

> **Adapts to your theme, automatically.** Every dot is drawn in a single
> colour taken live from your active Omarchy theme (the same
> `Color.foreground` / `Color.background` the bar and lock screen use) — no
> settings to touch, no palette to pick. Switch theme, including an
> automatic day/night switch, and Drift follows immediately.
>
> **Minimalist by design.** One colour, round dots, one shape-generating
> formula per scene, nothing else — no accents, no gradients, no motion
> trails. It reads as calm ambient motion rather than a busy demo effect.

## What it does

Drift replaces your idle screensaver with a small cloud of dots that folds
itself into an organic, paper-thin shape and keeps drifting as long as the
screensaver is shown. Four scenes are built in, and it rotates through
them one at a time: each time your screen goes idle it opens on the next
scene in the rotation and stays on that single scene, however long the
screensaver ends up staying up, right until you dismiss it (unlock, or any
real input). The *next* time it activates, it moves one step further
through the rotation, cycling through all four before repeating.

- **RAY**, **BIRD**, **WING** — a couple thousand tiny points, each
  positioned every frame by a closed-form parametric formula
  `(i, t) → (x, y)`. Stateless: nothing is remembered between frames, the
  whole shape is just where that formula happens to put every point at
  the current instant.
- **FLOCK** — a real flocking simulation (boids: separation, alignment,
  cohesion — Craig Reynolds, 1986; this plugin's version is a direct port
  of Daniel Shiffman's widely-used `Boid.pde` reference from *The Nature
  of Code*), the opposite of the other three: each dot carries a position
  and velocity forward from the previous frame and reacts to nearby dots
  with physically-grounded steering forces, which is what gives it the
  organic, unpredictable swooping and folding a fixed formula can't
  produce. Same single-colour, round-dot look as the other three; only
  what drives the motion differs.

## Install

```sh
omarchy plugin add https://github.com/riccardolanza05/omarchy-ray-screensaver --enable
omarchy restart shell
```

That's the whole install — no dependencies to fetch and no build step.
Drift is pure QML/JavaScript running inside `omarchy-shell` (Quickshell +
Qt6, which every Omarchy install already has); it adds nothing to your
system beyond the plugin's own files under
`~/.config/omarchy/plugins/<id>/`. The restart is needed: the shell loads
the new service before it fully lets go of the stock one, so a couple of
things (like the IPC calls under "Try it" below) only answer correctly
after that restart.

Drift **clones Omarchy's stock idle service** (`omarchy.idle`) instead of
running alongside it — the same pattern the
[Lock Screen Explorer](https://github.com/sirjul1337/lock-explorer) plugin
uses for `omarchy.lock`. It reproduces the stock idle → screensaver → lock
timeline exactly (same timeouts, same stay-awake behaviour); the only
difference is *what's drawn* at the screensaver stage. The manifest's
`clonedFrom: omarchy.idle` is what tells `omarchy plugin add --enable` to
swap the two automatically — **you end up with the stock `omarchy.idle`
service disabled and Drift enabled in its place**, not both running at
once (which would double-fire every idle event). Nothing else on your
system is touched, and it's reversible any time — see "Uninstall" below.

### Uninstall / going back to the stock screensaver

```sh
omarchy plugin remove io.github.riccardolanza05.omarchy-ray-screensaver
omarchy plugin enable omarchy.idle
```

The first command removes Drift and its files; the second turns the stock
idle/screensaver service back on. Both are ordinary, safe Omarchy plugin
operations — nothing outside `~/.config/omarchy/plugins/` and your
`shell.json` plugin list is touched either way.

## Try it without waiting for idle

```sh
omarchy-shell ray-screensaver preview   # show it now, advancing the rotation
omarchy-shell ray-screensaver status    # what it's doing right now (JSON)
omarchy-shell ray-screensaver disable   # hide it / pause idle handling
omarchy-shell ray-screensaver enable    # resume
```

Jump straight to one of the four scenes by index (0=RAY, 1=BIRD, 2=WING,
3=FLOCK) without disturbing the rotation's own position:

```sh
omarchy-shell ray-screensaver previewIndex 1   # BIRD, say
```

Two more calls exist for exercising the real idle machinery without
waiting out the real timeouts — `simulateIdle` goes through the same
`startIdleCycle()` a genuine idle timeout does, and `simulateLock`
triggers an actual lock immediately (same call the lock timer makes at
its real timeout — this really does lock your session, same as if the
timeout had just been reached):

```sh
omarchy-shell ray-screensaver simulateIdle
omarchy-shell ray-screensaver simulateLock
```

## How it works

- **Rendering**: each monitor gets its own fullscreen `PanelWindow`
  (Wayland layer-shell, `WlrLayer.Overlay`) holding a `Canvas` that repaints
  every frame. Points are grouped into two brightness passes per frame and,
  within each pass, only the roughly 1-in-29 "big" dots get an actual round
  (octagon) shape; the other ~97% are drawn with a plain `fillRect()` —
  square vs. round is not visually distinguishable at the ~1px size those
  render at, and skipping path construction for the vast majority of points
  is what keeps RAY/BIRD/WING's ~1700 points at a steady ~60fps.
- **FLOCK's simulation**: 1700 agents (matching RAY/BIRD/WING's point
  count), spawned clustered near the centre, each with its own position
  and velocity carried across frames. Every frame, each agent looks at
  nearby flockmates for separation and alignment — found via a spatial
  hash grid keyed by cell, not an all-pairs scan — and steers by three
  Reynolds rules, each a `steer = desired − velocity` seek force limited
  to a maximum, weighted and summed the same way as the Nature of Code
  reference this is ported from. Cohesion is the exception: every agent
  seeks the whole flock's single centroid (computed once per frame, O(n))
  rather than a locally-weighted average of nearby agents — simpler,
  cheaper at this point count, and what actually keeps it one flock
  instead of several permanent clusters (a shared or even a long local
  radius either let sub-groups drift out of range of each other, or degrades
  toward an all-pairs scan once the flock is packed tighter than that
  radius, which it reliably is). A minimum speed alongside the maximum
  keeps it lively (agents
  cruise around a third of top speed on average otherwise, since the three
  steering forces partly cancel). Edges are a soft steer-back, not a
  wraparound — a single cohesive flock straddling a wrap seam renders as
  two blobs at opposite edges of the screen, so this stays contained
  instead, the same "no visible seam, ever" RAY/BIRD/WING already have.
  Physics is stepped once per 16ms tick, decoupled from painting, which
  just draws whatever the simulation's current state is.
- **Colour**: read once per frame from the `qs.Commons` `Color` singleton
  that the rest of the Omarchy shell already uses, so a day/night theme
  switch is picked up live, mid-session.
- **Dismissal**: real input only. A grace period ignores everything for the
  first 2.5s after a scene opens (so the surface mapping under your cursor
  doesn't immediately dismiss it), and after that, mouse movement needs to
  clear a 3px threshold — not just "the mouse reported a position", which
  Wayland does once on its own the moment the surface gains hover — before
  it counts as a dismiss. A click or keypress dismisses immediately once
  past the grace period.
- **Idle timing**: unchanged from stock `omarchy.idle` — configured the
  same way, in `shell.json`'s `idle.screensaver` / `idle.lock` (seconds).

## Where the scenes come from

**RAY, BIRD, WING** are a 1:1 read of `setupHeroRay()` in
[plugins.omarchy.org](https://plugins.omarchy.org)'s own
`assets/js/app.js` — the hero animation on that site's homepage — verified
by fetching the file directly; it carries no comments, credit, or link to
a source of its own. It belongs to a genre of compact, trigonometry-driven
point-cloud sketches that circulates on X/Twitter under the hashtag
**#つぶやきProcessing** ("Tsubuyaki Processing" — sketches that fit in a
single tweet), most visibly through creators like
[@yuruyurau](https://x.com/yuruyurau). Drift credits that lineage but is
not a copy of any single named sketch — like the site's own version, it's
an independent implementation of the same style of formula. Three of the
site's six original scenes (ORIGINAL, COCOON, STORM) are intentionally
left out.

Two more scenes (WAVE, a rippled dot grid, and SPIRAL, a phyllotaxis
pattern) briefly lived here too and were removed to keep the plugin to
the original three — see this repo's commit history ("Add two
experimental scenes: WAVE and SPIRAL") to restore them.

**FLOCK** is a different style entirely — not part of `setupHeroRay()` or
the #つぶやきProcessing lineage above. It's a direct, credited port of
[Daniel Shiffman](https://github.com/shiffman)'s `Boid.pde` from
[*The Nature of Code*](https://natureofcode.com/)
([source](https://github.com/nature-of-code/noc-examples-processing/blob/master/chp06_agents/NOC_6_09_Flocking/Boid.pde)),
itself an implementation of **boids** (Craig Reynolds, 1986): separation,
alignment and cohesion, the classic three-rule flocking algorithm — same
per-rule weights (separation ×1.5, alignment/cohesion ×1) and the same
`steer = desired − velocity` seek force behind every rule. A few things
don't carry over verbatim, added after live testing surfaced real
problems: cohesion always targets the whole flock's single centroid
instead of a locally-weighted average within some "neighbordist" — a
shared or even a long local radius either let sub-groups drift out of
range of each other or, once this plugin's actual point count (1700,
matching RAY/BIRD/WING) packed the flock tighter than that radius,
degraded toward an all-pairs scan; the flock split into several permanent
clusters at least once along the way, which the centroid target rules out
entirely rather than just making less likely. Edges are a soft steer-back
instead of the reference's wraparound — a single cohesive flock straddling
a wrap seam renders as two blobs at opposite edges, which is what caused
that same split while crossing an edge, under the wraparound this used to
have. Agents also spawn clustered near the centre instead of scattered
across the whole screen, and separation/alignment neighbour search uses a
spatial hash grid instead of an all-pairs scan. Rendering is this plugin's
round dots instead of the reference's oriented triangles. Tracked as
[issue #1](https://github.com/riccardolanza05/omarchy-ray-screensaver/issues/1)
before being built.

## Requirements & dependencies

None beyond Omarchy itself. Drift is plain QML and JavaScript; it uses only
`Quickshell`, `Quickshell.Io`, `Quickshell.Wayland` and the shell's own
`qs.Commons` module, all of which ship with every Omarchy install. No
packages to install, no external services, no network access.

## Known limitations

- The rotation position only persists for as long as `omarchy-shell` keeps
  running (`keepLoaded: true` keeps it alive between idle cycles, but a
  full shell restart resets it) — it does not survive a logout/login.
- No per-user tuning knobs yet (point count, zoom, which scenes are in the
  rotation) — everything is fixed at the values that looked right during
  development. Contributions welcome.
- The external commands this service runs (`omarchy-system-lock`,
  `omarchy-system-wake`, and `mkdir` for the stay-awake state directory)
  are each invoked at a hardcoded absolute path rather than looked up by name,
  as a deliberate security hardening (see the commit history around the
  marketplace review) — this assumes the standard Arch/Omarchy filesystem
  layout. If a future Omarchy release ever moves one of those binaries,
  this plugin would need a matching update rather than picking the new
  location up on its own the way a `$PATH`-based lookup would have.
  Everything else — reading/writing the stay-awake marker, rendering,
  dismissal — runs no external process and no shell at all.

## Development

Drift was built in a pair-programming session with
[Claude Code](https://claude.com/claude-code) (Anthropic's CLI coding
agent) — from the initial port of the site's formula through every fix and
feature in this repo's commit history. Every change was verified live on
the author's own Omarchy machine (screenshots, frame-rate measurements,
and a real idle-cycle test) before being committed.

## License

MIT — see [LICENSE](./LICENSE). `Service.qml` is based on the built-in
`omarchy.idle` service from [Omarchy](https://github.com/omacom/omarchy)
(MIT). FLOCK's simulation is ported from Daniel Shiffman's `Boid.pde` in
[nature-of-code/noc-examples-processing](https://github.com/nature-of-code/noc-examples-processing)
(MIT) — see "Where the scenes come from" above.
