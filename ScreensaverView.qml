import QtQuick
import qs.Commons
import "Presets.js" as Presets

// One monitor's screensaver surface. Renders whichever scene from
// Presets.js is current (RAY/BIRD/WING are a near-verbatim port of
// setupHeroRay() from plugins.omarchy.org's assets/js/app.js — see the
// paintRay() note below; WAVE and SPIRAL are unrelated formulas), a cloud
// of tiny round dots every frame. Colour comes from the live Omarchy theme
// (Color.foreground on Color.background), a single colour for every dot —
// no accent, no per-point tinting.
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
  onPresetIndexChanged: if (root.active) presetStartedAt = Date.now()

  Timer {
    id: frameTimer
    interval: 16
    running: root.active
    repeat: true
    onTriggered: canvas.requestPaint()
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

    // A grid of dots rippled by two summed sine waves — the classic
    // three.js "particles waves" demo pattern: height(gx,gy,t) =
    // sin(gx*f+t) + sin(gy*f+t). Height bobs each dot vertically and (since
    // it also decides which of the two passes a dot falls into) makes wave
    // crests render bigger and brighter — the closest a flat single-colour
    // canvas gets to the original's 3D lighting.
    function paintWave(ctx, t, g) {
      var cols = Math.round(Math.sqrt(root.pointCount))
      var rows = Math.ceil(root.pointCount / cols)
      var sin = Math.sin
      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(g.fg.r, g.fg.g, g.fg.b, bright ? g.alphaBright : g.alphaFaint)
        ctx.beginPath()
        for (var i = 0; i < root.pointCount; i++) {
          var gx = i % cols, gy = Math.floor(i / cols)
          var nx = gx - (cols - 1) / 2, ny = gy - (rows - 1) / 2
          var height = sin(nx * 0.35 + t * 0.9) + sin(ny * 0.35 + t * 0.7)   // -2..2
          var hn = (height + 2) / 4   // 0..1
          if ((hn > 0.55) !== bright) continue
          var x = g.centerX + (nx * 12) * g.scale
          var py = g.centerY + (ny * 12 + height * 6) * g.scale
          if (x < 0 || x > g.w || py < 0 || py > g.h) continue
          if (hn > 0.55) dotBig(ctx, x, py, g.radiusLarge)
          else dotSmall(ctx, x, py, g.radiusSmall)
        }
        ctx.fill()
      }
    }

    // Phyllotaxis / Vogel spiral — the sunflower-seed-head pattern (public
    // domain math, no single author): point i sits at angle = i *
    // goldenAngle, radius = spacing * sqrt(i). Rotated over time and
    // breathing gently (radius pulses with sin(t)).
    function paintSpiral(ctx, t, g) {
      var goldenAngle = 2.399963
      var pulse = 1 + 0.15 * Math.sin(t * 0.5)
      var cos = Math.cos, sin = Math.sin, sqrt = Math.sqrt
      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(g.fg.r, g.fg.g, g.fg.b, bright ? g.alphaBright : g.alphaFaint)
        ctx.beginPath()
        for (var i = 0; i < root.pointCount; i++) {
          if (((i % 13) === 0) !== bright) continue
          var angle = i * goldenAngle + t * 0.15
          var radius = 2.2 * sqrt(i) * pulse
          var x = g.centerX + (radius * cos(angle)) * g.scale
          var py = g.centerY + (radius * sin(angle)) * g.scale
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
        // originX/originY assume the ray formula's own coordinate convention
        // (roughly a 0..400 box). Scenes with 0-centred coordinates — wave,
        // spiral — use centerX/centerY instead.
        originX: (w - 400.0 * scale) / 2.0 + panX,
        originY: (h - 400.0 * scale) / 2.0 + panY,
        centerX: w / 2.0 + panX,
        centerY: h / 2.0 + panY,
        radiusSmall: Math.max(0.4, 0.475 * unit),
        radiusLarge: Math.max(0.4, 0.75 * unit),
        alphaFaint: 0.27 * 0.84 * fade,
        alphaBright: 0.48 * 0.84 * fade
      }

      if (preset.kind === "wave") paintWave(ctx, t, g)
      else if (preset.kind === "spiral") paintSpiral(ctx, t, g)
      else paintRay(ctx, preset, t, fade, g)
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
