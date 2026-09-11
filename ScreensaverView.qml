import QtQuick
import qs.Commons
import "Presets.js" as Presets

// One monitor's screensaver surface. Renders whichever of the Presets.js
// entries is current, either of two ways: RAY/BIRD/WING are a near-verbatim
// port of setupHeroRay() from plugins.omarchy.org's assets/js/app.js (see
// paintRay() below) — every dot's position is recomputed from scratch each
// frame as a pure function of (i, t), no memory between frames. FLOCK (see
// paintFlock()/stepFlock() below) is the opposite: a real boids simulation,
// a direct port of Daniel Shiffman's Boid.pde (The Nature of Code,
// chp06_agents/NOC_6_09_Flocking) — each dot carries position + velocity
// forward from the previous frame and steers by three rules (separation,
// alignment, cohesion), each computed the way that reference does it:
// "steer = desired − velocity", limited to maxForce, not an ad-hoc direct
// push — which is what gives it believable, physically-grounded turns
// instead of jittery snapping. See issue #1. Colour comes from the live
// Omarchy theme (Color.foreground on Color.background), a single colour
// for every dot — no accent, no per-point tinting — in both cases.
Item {
  id: root

  // Which Presets.js entry is showing. The host (Service.qml) drives this
  // directly and it does not change again until the *next* activation — one
  // scene stays up for the whole time the screensaver is shown, and each
  // new activation moves one step further through the rotation.
  property int presetIndex: 0
  property real fadeSeconds: 0.22
  property bool active: false       // host toggles this to show/hide
  property real graceSeconds: 2.5   // ignore input this long after activating

  signal dismissed(string reason)

  property real presetStartedAt: 0
  property real activatedAt: 0

  // True while the current preset is the FLOCK boids scene — a live
  // binding (Presets.resolve() is a cheap pure function) so frameTimer
  // doesn't have to re-resolve the preset on every 16ms tick just to know
  // whether it needs to step the simulation.
  readonly property bool boidsKind: Presets.resolve(presetIndex).kind === "boids"

  // Picked to hold a steady 58-61fps on the heaviest scene (RAY) — dialled
  // down from a denser 4500 (measured 46-60fps, occasionally short of 60)
  // for a firm 60fps instead, then nudged back up slightly from an
  // initial 1400 for a bit more density at the same frame rate. The
  // dotBig/dotSmall split below (see there) is what makes any of this
  // affordable — path-and-tessellate every point (what an earlier version
  // did) measured ~5fps at 3600.
  readonly property int pointCount: 1700

  // Unit-circle vertices for an 8-sided dot polygon, built once (not per
  // point, not per frame), used only for the "big" 1-in-29 dots — see
  // dotBig/dotSmall below. Straight lineTo() segments rasterize far cheaper
  // than ctx.arc()'s curve tessellation, and at the size those dots render
  // at, an octagon looks just as round.
  readonly property var octX: [1, 0.7071, 0, -0.7071, -1, -0.7071, 0, 0.7071]
  readonly property var octY: [0, 0.7071, 1, 0.7071, 0, -0.7071, -1, -0.7071]

  function elapsed(from) { return (Date.now() - from) / 1000 }

  // Set once the grace period ends, by the first mouse-position report that
  // arrives after it — not a dismiss in itself, just a baseline to measure
  // real movement against afterwards. -1 means "not set yet".
  property real refMouseX: -1
  property real refMouseY: -1

  function activate() {
    presetStartedAt = Date.now()
    activatedAt = Date.now()
    refMouseX = -1
    refMouseY = -1
    // A fresh flock each time the scene (re)starts — same spirit as
    // presetStartedAt resetting the formula scenes' clock to 0: whichever
    // scene is showing opens on a clean, unrepeated start every activation.
    canvas.flockNeedsReset = true
    canvas.requestPaint()
  }

  // Click and key presses are unambiguous — dismiss immediately once past
  // the grace period.
  function maybeDismiss(reason) {
    if (!root.active) return
    if (elapsed(root.activatedAt) < root.graceSeconds) return
    root.dismissed(reason)
  }

  // Mouse movement needs a minimum distance, not just "a position changed":
  // Qt/Wayland reports a position the moment a MouseArea gains hover (e.g.
  // right as this surface maps under an already-stationary cursor) even
  // though the mouse never actually moved, and — with no threshold — that
  // single synthetic report was enough to dismiss the screensaver within a
  // couple of seconds of it opening, every time. 3px, matching the
  // move-to-dismiss threshold the desktop prototype this is based on used.
  function maybeDismissOnMove(mx, my) {
    if (!root.active) return
    if (elapsed(root.activatedAt) < root.graceSeconds) return
    if (root.refMouseX < 0) { root.refMouseX = mx; root.refMouseY = my; return }
    var dx = mx - root.refMouseX, dy = my - root.refMouseY
    if (dx * dx + dy * dy < 9) return   // < 3px
    root.dismissed("mouse-move dx=" + dx.toFixed(1) + " dy=" + dy.toFixed(1))
  }

  onActiveChanged: if (active) activate()
  onPresetIndexChanged: if (root.active) {
    presetStartedAt = Date.now()
    canvas.flockNeedsReset = true
  }

  Timer {
    id: frameTimer
    interval: 16
    running: root.active
    repeat: true
    onTriggered: {
      // Physics is stepped here, once per tick, at a fixed dt — decoupled
      // from onPaint, which may repaint more than once per tick (e.g. on
      // an expose event) and must stay a pure "draw current state" step.
      if (root.boidsKind && canvas.width > 0 && canvas.height > 0)
        canvas.stepFlock(1 / 60, canvas.width, canvas.height)
      canvas.requestPaint()
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    // FramebufferObject keeps the rendered frame GPU-resident instead of a
    // CPU image that has to be re-uploaded as a texture every frame.
    renderTarget: Canvas.FramebufferObject
    renderStrategy: Canvas.Cooperative

    // Stamps one point's octagon into the currently-open path — for the
    // "big" 1-in-29 dots, which are large enough that their shape actually
    // reads. Everything else uses plain fillRect() instead (see dotSmall
    // below): at the ~1px size the other 28/29 render at, square vs. round
    // is not distinguishable, and skipping path/tessellation entirely for
    // the vast majority of points is what makes a much higher point count
    // affordable.
    function dotBig(ctx, x, y, r) {
      var ox = root.octX, oy = root.octY
      ctx.moveTo(x + ox[0] * r, y + oy[0] * r)
      for (var v = 1; v < 8; v++) ctx.lineTo(x + ox[v] * r, y + oy[v] * r)
    }

    function dotSmall(ctx, x, y, r) {
      ctx.fillRect(x - r, y - r, r + r, r + r)
    }

    // --- FLOCK: boids, ported from Shiffman's Boid.pde -----------------
    //
    // The reference (The Nature of Code, chp06_agents/NOC_6_09_Flocking)
    // gives each boid an accumulated acceleration, reset every frame, that
    // three rules add into via `applyForce`: separate() (×1.5), align()
    // (×1) and cohesion() (×1) — see the class-level comment for how
    // faithfully this follows it. Every one of those three rules reduces
    // to the same primitive, `seek(target)`: steer = desired − velocity,
    // where desired is the direction to the target at maxSpeed, and the
    // result is clamped to maxForce. Separation's "target" is a point
    // pushed away from crowding neighbours; alignment's is the average
    // neighbour velocity; cohesion's is the average neighbour position.
    // velocity += acceleration, clamped to maxSpeed, then position +=
    // velocity, same as the reference's update().
    //
    // Four departures from a verbatim port, all added after live testing
    // on real hardware surfaced real problems a Node-only prototype
    // hadn't (see issue #1's research notes for the full trail):
    //
    // 1. Cohesion targets the whole flock's centroid (computed once per
    //    frame, O(n)) unconditionally, instead of a per-boid weighted
    //    average over nearby boids within some "neighbordist" the way the
    //    reference does. Earlier attempts tried a local cohesion radius
    //    (shared with alignment, then a separate long-range one, then a
    //    conditional centroid fallback for stragglers) and every version
    //    either let the flock split into permanent sub-clusters (a small
    //    shared radius: agents outside it feel no pull back toward the
    //    group at all) or, at this plugin's actual point count (1700,
    //    matching RAY/BIRD/WING), made the per-boid neighbour scan
    //    degrade toward O(n²) once the flock packs tighter than the
    //    cohesion radius — which it does, reliably, once cohesive. A
    //    single global centroid target is both O(n) total and a strictly
    //    stronger guarantee: there is no radius for a sub-group to drift
    //    outside of.
    // 2. No wraparound. The reference (and every other flocking reference
    //    checked for issue #1) teleports agents to the opposite edge, but
    //    that assumes many small, independent clusters where one agent
    //    quietly reappearing elsewhere is unremarkable. A single cohesive
    //    flock straddling that seam instead renders as two blobs at
    //    opposite edges of the screen — observed live, together with (1)
    //    above, as a flock that split in two while crossing an edge and
    //    never re-merged — so this steers gently back inward near an edge
    //    instead (same "no visible seam, ever" property RAY/BIRD/WING
    //    already have). The hard clamp underneath that soft steer (a
    //    safety net for a stray large dt) zeroes the outward velocity
    //    component instead of just clamping position, so a fast agent
    //    can't smear along the wall.
    // 3. A minimum speed, alongside the maximum: without it agents cruise
    //    around 35% of top speed on average (the three steering forces
    //    partially cancel most of the time), which reads as sluggish
    //    regardless of how high the maximum is raised.
    // 4. Agents spawn clustered in a disc near the centre instead of
    //    scattered uniformly across the whole screen, so the flock starts
    //    as one group instead of needing to discover itself out of
    //    scattered fragments.
    //
    // Separation and alignment neighbour lookup also isn't ported
    // verbatim: the reference scans every other boid for each rule
    // (O(n) per rule); this uses a spatial hash grid, cell size =
    // flockAlignR, so a 3x3 block already covers both radii — see
    // stepFlock().
    readonly property int flockCount: 1700
    property bool flockReady: false
    property bool flockNeedsReset: true
    property var flockX: []
    property var flockY: []
    property var flockVX: []
    property var flockVY: []
    // Tuned as fractions of min(width, height) in initFlock() so the flock
    // reads the same regardless of monitor resolution — same idea as the
    // formula scenes' `ref`/`scale` in onPaint below.
    property real flockSeparationR: 0
    property real flockAlignR: 0
    property real flockCell: 0
    property real flockMaxSpeed: 0
    property real flockMinSpeed: 0
    property real flockMaxForce: 0
    property real flockMargin: 0
    property real flockEdgeForce: 0

    function initFlock(w, h) {
      var ref = Math.max(1, Math.min(w, h))
      flockSeparationR = ref * 0.032
      flockAlignR = ref * 0.05
      flockCell = flockAlignR
      flockMaxSpeed = ref * 0.28
      flockMinSpeed = flockMaxSpeed * 0.6
      flockMaxForce = ref * 0.34
      // Sized to the actual stopping distance at flockMaxSpeed
      // (v²/(2·edgeForce/mass), edgeForce averaging ~half its peak over
      // the ramp) — a margin much narrower than this let agents reach the
      // hard clamp at full speed and smear along the wall instead of
      // turning away from it in time.
      flockMargin = ref * 0.20
      flockEdgeForce = flockMaxForce * 3.0

      var n = flockCount
      var X = [], Y = [], VX = [], VY = []
      var cx0 = w / 2, cy0 = h / 2, spawnR = ref * 0.12
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2, r = Math.sqrt(Math.random()) * spawnR
        X.push(cx0 + Math.cos(a) * r)
        Y.push(cy0 + Math.sin(a) * r)
        var ang = Math.random() * Math.PI * 2
        var sp = flockMaxSpeed * (0.5 + Math.random() * 0.5)
        VX.push(Math.cos(ang) * sp)
        VY.push(Math.sin(ang) * sp)
      }
      flockX = X; flockY = Y; flockVX = VX; flockVY = VY
      flockReady = true
      flockNeedsReset = false
    }

    // seek(): Reynolds' "steer = desired − velocity", limited to maxForce.
    // (tx, ty) is the target direction (not yet normalized); (vx, vy) is
    // this boid's current velocity. Returns [steerX, steerY].
    function flockSeek(tx, ty, vx, vy) {
      var m = Math.sqrt(tx * tx + ty * ty)
      if (m < 0.0001) return [0, 0]
      var dx = tx / m * flockMaxSpeed, dy = ty / m * flockMaxSpeed
      var sx = dx - vx, sy = dy - vy
      var sm = Math.sqrt(sx * sx + sy * sy)
      if (sm > flockMaxForce) { sx = sx / sm * flockMaxForce; sy = sy / sm * flockMaxForce }
      return [sx, sy]
    }

    function stepFlock(dt, w, h) {
      if (!flockReady) return
      var n = flockCount
      var X = flockX, Y = flockY, VX = flockVX, VY = flockVY
      var cell = flockCell
      if (cell <= 0) return

      // Bucket every agent into a coarse grid keyed by "col,row" once per
      // frame — turns each agent's neighbour search below into "check my
      // cell and its 8 neighbours" instead of scanning all n agents.
      var grid = {}
      for (var gi = 0; gi < n; gi++) {
        var key = Math.floor(X[gi] / cell) + "," + Math.floor(Y[gi] / cell)
        var bucket = grid[key]
        if (bucket) bucket.push(gi); else grid[key] = [gi]
      }

      var sepR2 = flockSeparationR * flockSeparationR
      var aliR2 = flockAlignR * flockAlignR

      // Whole-flock centroid, O(n) — cohesion's target for every agent,
      // unconditionally (see the class-level comment, point 1).
      var centroidX = 0, centroidY = 0
      for (var ci = 0; ci < n; ci++) { centroidX += X[ci]; centroidY += Y[ci] }
      centroidX /= n; centroidY /= n

      var newVX = new Array(n), newVY = new Array(n)

      for (var i = 0; i < n; i++) {
        var xi = X[i], yi = Y[i], vxi = VX[i], vyi = VY[i]
        var cx = Math.floor(xi / cell), cy = Math.floor(yi / cell)

        var sepX = 0, sepY = 0, sepCount = 0
        var sumVX = 0, sumVY = 0, aliCount = 0

        // Short-range window: separation + alignment (cell = flockAlignR,
        // so a 3x3 block already covers both radii).
        for (var gx = cx - 1; gx <= cx + 1; gx++) {
          for (var gy = cy - 1; gy <= cy + 1; gy++) {
            var nb = grid[gx + "," + gy]
            if (!nb) continue
            for (var b = 0; b < nb.length; b++) {
              var j = nb[b]
              if (j === i) continue
              var dx = xi - X[j], dy = yi - Y[j]
              var d2 = dx * dx + dy * dy
              if (d2 <= 0.0001) continue
              // Separation: away from the neighbour, weighted by 1/distance
              // (diff.normalize().div(d) in the reference — the same as
              // dividing the raw offset by d²).
              if (d2 < sepR2) { sepX += dx / d2; sepY += dy / d2; sepCount++ }
              if (d2 < aliR2) { sumVX += VX[j]; sumVY += VY[j]; aliCount++ }
            }
          }
        }

        var ax = 0, ay = 0

        if (sepCount > 0) {
          var s = flockSeek(sepX / sepCount, sepY / sepCount, vxi, vyi)
          ax += s[0] * 1.5; ay += s[1] * 1.5
        }
        if (aliCount > 0) {
          var a = flockSeek(sumVX / aliCount, sumVY / aliCount, vxi, vyi)
          ax += a[0]; ay += a[1]
        }
        // Cohesion: unconditionally the whole flock's centroid (see the
        // class-level comment, point 1) — no radius, no neighbour scan.
        var c = flockSeek(centroidX - xi, centroidY - yi, vxi, vyi)
        ax += c[0]; ay += c[1]

        // Soft containment — steer back in near an edge instead of
        // wrapping (see the class-level comment, point 2).
        var m = flockMargin, ef = flockEdgeForce
        if (xi < m) ax += ef * (1 - xi / m)
        else if (xi > w - m) ax -= ef * (1 - (w - xi) / m)
        if (yi < m) ay += ef * (1 - yi / m)
        else if (yi > h - m) ay -= ef * (1 - (h - yi) / m)

        var vx = vxi + ax * dt, vy = vyi + ay * dt
        var sp = Math.sqrt(vx * vx + vy * vy)
        if (sp > flockMaxSpeed) { vx = vx / sp * flockMaxSpeed; vy = vy / sp * flockMaxSpeed }
        else if (sp > 0.0001 && sp < flockMinSpeed) { vx = vx / sp * flockMinSpeed; vy = vy / sp * flockMinSpeed }
        newVX[i] = vx; newVY[i] = vy
      }

      for (var k = 0; k < n; k++) {
        VX[k] = newVX[k]; VY[k] = newVY[k]
        X[k] += VX[k] * dt
        Y[k] += VY[k] * dt
        // Hard clamp underneath the soft containment above — a safety
        // net for a stray large dt, not the normal path. Zeroes the
        // outward velocity component instead of just clamping position,
        // so a fast agent can't smear along the wall.
        if (X[k] < 0) { X[k] = 0; if (VX[k] < 0) VX[k] = 0 }
        else if (X[k] > w) { X[k] = w; if (VX[k] > 0) VX[k] = 0 }
        if (Y[k] < 0) { Y[k] = 0; if (VY[k] < 0) VY[k] = 0 }
        else if (Y[k] > h) { Y[k] = h; if (VY[k] > 0) VY[k] = 0 }
      }
    }

    // Same two-brightness-pass, big/small-dot split as paintRay() (see
    // there for why), just reading live simulation state instead of
    // evaluating a formula.
    function paintFlock(ctx, g) {
      var n = flockCount, X = flockX, Y = flockY
      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(g.fg.r, g.fg.g, g.fg.b, bright ? g.alphaBright : g.alphaFaint)
        ctx.beginPath()
        for (var i = 0; i < n; i++) {
          if (((i % 13) === 0) !== bright) continue
          var x = X[i], y = Y[i]
          if (x < 0 || x > g.w || y < 0 || y > g.h) continue
          if ((i % 29) === 0) dotBig(ctx, x, y, g.radiusLarge)
          else dotSmall(ctx, x, y, g.radiusSmall)
        }
        ctx.fill()
      }
    }

    // The setupHeroRay() formula (see the file header). `g` bundles the
    // shared per-frame setup every scene needs (origin/scale/colours/etc.)
    function paintRay(ctx, preset, t, fade, g) {
      var v = preset.values
      var AMP = v.AMP, WIND = v.WIND, VS = v.VS, VO = v.VO, QA = v.QA, QF = v.QF
      var SP = v.SP, TH = v.TH, ORB = v.ORB, YS = v.YS, PD = v.PD, PSP = v.PSP
      var WV = v.WV, WSP = v.WSP, DOF = v.DOF, RF = v.RF, DPH = v.DPH
      var CX = v.CX, CY = v.CY, offsetY = preset.offsetY
      var STRIDE = 6000.0 / root.pointCount
      var cos = Math.cos, sin = Math.sin, sqrt = Math.sqrt

      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(g.fg.r, g.fg.g, g.fg.b, bright ? g.alphaBright : g.alphaFaint)
        ctx.beginPath()
        for (var i = 0; i < root.pointCount; i++) {
          if (((i % 13) === 0) !== bright) continue
          var si = i * STRIDE
          var y = si / 235.0
          var k = (AMP + cos(si / PD - t * PSP)) * cos(si / WIND)
          var e = y / VS - VO
          var distance = sqrt(k * k + e * e) + sin(e / WV + t / WSP) - DOF
          var q = QA * sin(k * QF) - y / SP * k * (TH + k * sin(cos(e) * RF - distance * DPH + t))
          var angle = distance - t
          var x = g.originX + (q + ORB * cos(angle) + CX) * g.scale
          var py = g.originY + (q * sin(angle) + distance * YS + CY + offsetY) * g.scale
          if (x < 0 || x > g.w || py < 0 || py > g.h) continue
          if ((i % 29) === 0) dotBig(ctx, x, py, g.radiusLarge)
          else dotSmall(ctx, x, py, g.radiusSmall)
        }
        ctx.fill()
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      if (w <= 0 || h <= 0) return

      var preset = Presets.resolve(root.presetIndex)
      var secs = root.elapsed(root.presetStartedAt)
      var t = secs * 1.05   // seconds -> the site's slow clock (1000 * 0.00105)

      var fadeSecs = root.fadeSeconds
      var fade = 1.0
      if (fadeSecs > 0) {
        var f = Math.min(1.0, secs / fadeSecs)
        fade = 0.3 + 0.7 * (f * f * (3 - 2 * f))
      }

      var fg = Color.foreground
      var bg = Color.background
      ctx.globalAlpha = 1.0
      ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, 1.0)
      ctx.fillRect(0, 0, w, h)

      var zoom = preset.zoom * 2.0   // DEFAULT_ZOOM: the site's ~270px band, enlarged
      var scale = Math.min(w / 400.0, h / 400.0) * zoom
      var ref = Math.min(w, h)
      var panX = -0.03 * ref, panY = 0.05 * ref
      var unit = Math.pow(Math.max(1.0, scale), 0.62)

      var g = {
        w: w, h: h, fg: fg, scale: scale,
        originX: (w - 400.0 * scale) / 2.0 + panX,
        originY: (h - 400.0 * scale) / 2.0 + panY,
        radiusSmall: Math.max(0.4, 0.475 * unit),
        radiusLarge: Math.max(0.4, 0.75 * unit),
        alphaFaint: 0.27 * 0.84 * fade,
        alphaBright: 0.48 * 0.84 * fade
      }

      if (preset.kind === "boids") {
        if (flockNeedsReset || !flockReady) initFlock(w, h)
        paintFlock(ctx, g)
      } else {
        paintRay(ctx, preset, t, fade, g)
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onPositionChanged: function(mouse) { root.maybeDismissOnMove(mouse.x, mouse.y) }
    onClicked: root.maybeDismiss("click")
  }

  Keys.onPressed: function(event) {
    root.maybeDismiss("key=" + event.key)
    event.accepted = true
  }

  focus: root.active
}
