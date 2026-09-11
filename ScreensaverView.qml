import QtQuick
import qs.Commons
import "Presets.js" as Presets

// One monitor's screensaver surface. A near-verbatim port of setupHeroRay()
// from plugins.omarchy.org's assets/js/app.js: a closed-form parametric
// formula positions thousands of tiny round dots every frame (the site
// itself draws squares; this draws circles — see the note above the fill
// loop below). Colour comes from the live Omarchy theme (Color.foreground on
// Color.background), a single colour for every dot — no accent, no
// per-point tinting.
Item {
  id: root

  // Which of the three kept presets (RAY=0, BIRD=1, WING=2) is showing. The
  // host drives this directly (both the initial choice and the in-session
  // hold-cycle advance) so every monitor's surface changes preset at exactly
  // the same moment — each surface has its own Canvas and its own clock, but
  // none of them decide on their own when to move to the next preset.
  property int presetIndex: 0
  property real fadeSeconds: 0.22
  property bool active: false       // host toggles this to show/hide
  property real graceSeconds: 2.5   // ignore input this long after activating

  signal dismissed()

  property real presetStartedAt: 0
  property real activatedAt: 0

  // The site's own point count (3600) measured at ~5fps here with round
  // dots — Qt's Canvas tessellates each one into curves internally, and
  // that (not the point-placement maths, which stays under 3ms even at
  // 3600) turned out to be the real per-frame cost. Traded down for frame
  // rate: 900 points renders at ~40-50fps.
  readonly property int pointCount: 900

  // Unit-circle vertices for an 8-sided dot polygon, built once (not per
  // point, not per frame). Straight lineTo() segments rasterize far cheaper
  // than ctx.arc()'s curve tessellation, and at the 1-3px sizes these dots
  // render at, an octagon looks just as round.
  readonly property var octX: [1, 0.7071, 0, -0.7071, -1, -0.7071, 0, 0.7071]
  readonly property var octY: [0, 0.7071, 1, 0.7071, 0, -0.7071, -1, -0.7071]

  function elapsed(from) { return (Date.now() - from) / 1000 }

  function activate() {
    presetStartedAt = Date.now()
    activatedAt = Date.now()
    canvas.requestPaint()
  }

  function maybeDismiss() {
    if (!root.active) return
    if (elapsed(root.activatedAt) < root.graceSeconds) return
    root.dismissed()
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

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      if (w <= 0 || h <= 0) return

      var preset = Presets.resolve(root.presetIndex)
      var v = preset.values
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
      var originX = (w - 400.0 * scale) / 2.0 + panX
      var originY = (h - 400.0 * scale) / 2.0 + panY

      var unit = Math.pow(Math.max(1.0, scale), 0.62)
      var radiusSmall = Math.max(0.4, 0.475 * unit)
      var radiusLarge = Math.max(0.4, 0.75 * unit)

      var AMP = v.AMP, WIND = v.WIND, VS = v.VS, VO = v.VO, QA = v.QA, QF = v.QF
      var SP = v.SP, TH = v.TH, ORB = v.ORB, YS = v.YS, PD = v.PD, PSP = v.PSP
      var WV = v.WV, WSP = v.WSP, DOF = v.DOF, RF = v.RF, DPH = v.DPH
      var CX = v.CX, CY = v.CY, offsetY = preset.offsetY

      var STRIDE = 6000.0 / root.pointCount
      var alphaFaint = 0.27 * 0.84 * fade
      var alphaBright = 0.48 * 0.84 * fade
      var cos = Math.cos, sin = Math.sin, sqrt = Math.sqrt
      var ox = root.octX, oy = root.octY

      // Two passes (faint, then bright), each building ONE path out of every
      // point's 8-sided dot (moveTo + 7 lineTo, no intermediate fill) and
      // filling it once at the end — one fill() per pass instead of
      // thousands, and octagons instead of arcs (see octX/octY above).
      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, bright ? alphaBright : alphaFaint)
        ctx.beginPath()
        for (var i = 0; i < root.pointCount; i++) {
          if (((i % 13) === 0) !== bright) continue
          var si = i * STRIDE
          var y = si / 235.0
          var k = (AMP + cos(si / PD - t * PSP)) * cos(si / WIND)
          var e = y / VS - VO
          var kk = k * k, ee = e * e
          var distance = sqrt(kk + ee) + sin(e / WV + t / WSP) - DOF
          var q = QA * sin(k * QF) - y / SP * k * (TH + k * sin(cos(e) * RF - distance * DPH + t))
          var angle = distance - t
          var x = originX + (q + ORB * cos(angle) + CX) * scale
          var py = originY + (q * sin(angle) + distance * YS + CY + offsetY) * scale
          if (x < 0 || x > w || py < 0 || py > h) continue
          var big = (i % 29) === 0
          var r = big ? radiusLarge : radiusSmall
          ctx.moveTo(x + ox[0] * r, py + oy[0] * r)
          for (var v = 1; v < 8; v++) ctx.lineTo(x + ox[v] * r, py + oy[v] * r)
        }
        ctx.fill()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onPositionChanged: root.maybeDismiss()
    onClicked: root.maybeDismiss()
  }

  Keys.onPressed: function(event) {
    root.maybeDismiss()
    event.accepted = true
  }

  focus: root.active
}
