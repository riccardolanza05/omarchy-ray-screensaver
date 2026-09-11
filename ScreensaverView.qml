import QtQuick
import qs.Commons
import "Presets.js" as Presets

// One monitor's screensaver surface. Renders whichever of the Presets.js
// entries is current, either of two ways: RAY/BIRD/WING are a near-verbatim
// port of setupHeroRay() from plugins.omarchy.org's assets/js/app.js (see
// paintRay() below) — every dot's position is recomputed from scratch each
// frame as a pure function of (i, t), no memory between frames. FLOCK (see
// paintFlock()/stepFlock() below) is the opposite: a real boids simulation
// where each dot carries position + velocity forward from the previous
// frame and reacts to its neighbours (separation/alignment/cohesion), which
// is what gives it the organic, unpredictable swooping motion a fixed
// formula can't produce — see issue #1. Colour comes from the live Omarchy
// theme (Color.foreground on Color.background), a single colour for every
// dot — no accent, no per-point tinting — in both cases.
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

    // --- FLOCK: boids (Craig Reynolds, 1986) --------------------------
    //
    // A real simulation, not a formula: every agent carries (x, y, vx, vy)
    // forward across frames, and each frame it steers by three local
    // rules — separation, alignment, cohesion — computed only against
    // nearby flockmates, found via a spatial hash grid (cell size = the
    // largest of the three perception radii) so cost stays close to O(n)
    // instead of the O(n²) a naive all-pairs check would be. A mild
    // steer-away-from-the-edges force keeps every agent on screen forever
    // — no wraparound, no teleporting — so, like the formula scenes, this
    // one never has a seam either: it's an unbroken simulation for as long
    // as the scene stays up, only ever reseeded (initFlock) on a fresh
    // activation, the same moment the formula scenes reset their clock.
    readonly property int flockCount: 500
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
    property real flockCohesionR: 0
    property real flockPerceptionR: 0
    property real flockEdgeMargin: 0
    property real flockMaxSpeed: 0
    property real flockMinSpeed: 0
    property real flockMaxForce: 0

    function initFlock(w, h) {
      var ref = Math.max(1, Math.min(w, h))
      flockSeparationR = ref * 0.022
      flockAlignR = ref * 0.05
      flockCohesionR = ref * 0.055
      flockPerceptionR = Math.max(flockSeparationR, flockAlignR, flockCohesionR)
      flockEdgeMargin = ref * 0.08
      flockMaxSpeed = ref * 0.11
      flockMinSpeed = ref * 0.05
      flockMaxForce = ref * 0.16

      var n = flockCount
      var X = [], Y = [], VX = [], VY = []
      for (var i = 0; i < n; i++) {
        X.push(Math.random() * w)
        Y.push(Math.random() * h)
        var ang = Math.random() * Math.PI * 2
        var sp = flockMinSpeed + Math.random() * (flockMaxSpeed - flockMinSpeed)
        VX.push(Math.cos(ang) * sp)
        VY.push(Math.sin(ang) * sp)
      }
      flockX = X; flockY = Y; flockVX = VX; flockVY = VY
      flockReady = true
      flockNeedsReset = false
    }

    function stepFlock(dt, w, h) {
      if (!flockReady) return
      var n = flockCount
      var X = flockX, Y = flockY, VX = flockVX, VY = flockVY
      var cell = flockPerceptionR
      if (cell <= 0) return

      // Bucket every agent into a coarse grid keyed by "col,row" once per
      // frame; O(n) to build, and turns each agent's neighbour search
      // below into "check my cell and its 8 neighbours" instead of "check
      // every other agent".
      var grid = {}
      for (var gi = 0; gi < n; gi++) {
        var key = Math.floor(X[gi] / cell) + "," + Math.floor(Y[gi] / cell)
        var bucket = grid[key]
        if (bucket) bucket.push(gi); else grid[key] = [gi]
      }

      var sepR2 = flockSeparationR * flockSeparationR
      var aliR2 = flockAlignR * flockAlignR
      var cohR2 = flockCohesionR * flockCohesionR
      var maxR2 = Math.max(sepR2, aliR2, cohR2)
      var maxF = flockMaxForce, maxS = flockMaxSpeed, minS = flockMinSpeed
      var margin = flockEdgeMargin, edgeForce = maxF * 1.4

      var newVX = new Array(n), newVY = new Array(n)

      for (var i = 0; i < n; i++) {
        var xi = X[i], yi = Y[i]
        var cx = Math.floor(xi / cell), cy = Math.floor(yi / cell)
        var sepX = 0, sepY = 0
        var aliX = 0, aliY = 0, aliCount = 0
        var cohX = 0, cohY = 0, cohCount = 0

        for (var gx = cx - 1; gx <= cx + 1; gx++) {
          for (var gy = cy - 1; gy <= cy + 1; gy++) {
            var nb = grid[gx + "," + gy]
            if (!nb) continue
            for (var b = 0; b < nb.length; b++) {
              var j = nb[b]
              if (j === i) continue
              var dx = X[j] - xi, dy = Y[j] - yi
              var d2 = dx * dx + dy * dy
              if (d2 > maxR2) continue
              if (d2 < sepR2 && d2 > 0.0001) {
                var inv = 1 / d2
                sepX -= dx * inv; sepY -= dy * inv
              }
              if (d2 < aliR2) { aliX += VX[j]; aliY += VY[j]; aliCount++ }
              if (d2 < cohR2) { cohX += X[j]; cohY += Y[j]; cohCount++ }
            }
          }
        }

        var ax = 0, ay = 0

        var sepLen = Math.sqrt(sepX * sepX + sepY * sepY)
        if (sepLen > 0.0001) { ax += (sepX / sepLen) * maxF; ay += (sepY / sepLen) * maxF }

        if (aliCount > 0) {
          var avx = aliX / aliCount, avy = aliY / aliCount
          var al = Math.sqrt(avx * avx + avy * avy)
          if (al > 0.0001) { ax += (avx / al) * maxF * 0.6; ay += (avy / al) * maxF * 0.6 }
        }

        if (cohCount > 0) {
          var tx = cohX / cohCount - xi, ty = cohY / cohCount - yi
          var cl = Math.sqrt(tx * tx + ty * ty)
          if (cl > 0.0001) { ax += (tx / cl) * maxF * 0.5; ay += (ty / cl) * maxF * 0.5 }
        }

        // Soft steer back in from the edges — never a hard wall, never a
        // wraparound teleport, so there's nothing for the eye to catch as
        // a cut.
        if (xi < margin) ax += edgeForce * (1 - xi / margin)
        else if (xi > w - margin) ax -= edgeForce * (1 - (w - xi) / margin)
        if (yi < margin) ay += edgeForce * (1 - yi / margin)
        else if (yi > h - margin) ay -= edgeForce * (1 - (h - yi) / margin)

        var vx = VX[i] + ax * dt
        var vy = VY[i] + ay * dt
        var sp = Math.sqrt(vx * vx + vy * vy)
        if (sp > maxS) { vx = vx / sp * maxS; vy = vy / sp * maxS }
        else if (sp > 0.0001 && sp < minS) { vx = vx / sp * minS; vy = vy / sp * minS }
        newVX[i] = vx; newVY[i] = vy
      }

      for (var k = 0; k < n; k++) {
        VX[k] = newVX[k]; VY[k] = newVY[k]
        X[k] += VX[k] * dt
        Y[k] += VY[k] * dt
        // A hard clamp underneath the soft edge steer — a safety net for
        // a stray large dt (e.g. after a stutter), not the normal path.
        if (X[k] < 0) X[k] = 0; else if (X[k] > w) X[k] = w
        if (Y[k] < 0) Y[k] = 0; else if (Y[k] > h) Y[k] = h
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
