import QtQuick
import qs.Commons
import "Presets.js" as Presets

// One monitor's screensaver surface. A near-verbatim port of setupHeroRay()
// from plugins.omarchy.org's assets/js/app.js: a closed-form parametric
// formula draws thousands of tiny squares into a canvas every frame. Colour
// comes from the live Omarchy theme (Color.foreground on Color.background),
// a single colour for every dot — no accent, no per-point tinting.
Item {
  id: root

  // Which of the three kept presets (RAY=0, BIRD=1, WING=2) is showing. The
  // host drives this directly (both the initial choice and the in-session
  // hold-cycle advance) so every monitor's surface changes preset at exactly
  // the same moment — each surface has its own Canvas and its own clock, but
  // none of them decide on their own when to move to the next preset.
  property int presetIndex: 0
  property real fadeSeconds: 0.22
  property real trail: 0.6          // background repaint alpha; 1.0 = hard clear
  property bool active: false       // host toggles this to show/hide
  property real graceSeconds: 2.5   // ignore input this long after activating

  signal dismissed()

  property real presetStartedAt: 0
  property real activatedAt: 0
  property bool forceClear: true

  function elapsed(from) { return (Date.now() - from) / 1000 }

  function activate() {
    presetStartedAt = Date.now()
    activatedAt = Date.now()
    forceClear = true
    canvas.requestPaint()
  }

  function maybeDismiss() {
    if (!root.active) return
    if (elapsed(root.activatedAt) < root.graceSeconds) return
    root.dismissed()
  }

  onActiveChanged: if (active) activate()
  onPresetIndexChanged: if (root.active) {
    presetStartedAt = Date.now()
    forceClear = true
  }

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
      var trailA = root.forceClear ? 1.0 : root.trail
      root.forceClear = false
      ctx.globalAlpha = 1.0
      ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, trailA)
      ctx.fillRect(0, 0, w, h)

      var zoom = preset.zoom * 2.0   // DEFAULT_ZOOM: the site's ~270px band, enlarged
      var scale = Math.min(w / 400.0, h / 400.0) * zoom
      var ref = Math.min(w, h)
      var panX = -0.03 * ref, panY = 0.05 * ref
      var originX = (w - 400.0 * scale) / 2.0 + panX
      var originY = (h - 400.0 * scale) / 2.0 + panY

      var unit = Math.pow(Math.max(1.0, scale), 0.62)
      var sizeSmall = Math.max(0.8, 0.95 * unit)
      var sizeLarge = Math.max(0.8, 1.50 * unit)

      var AMP = v.AMP, WIND = v.WIND, VS = v.VS, VO = v.VO, QA = v.QA, QF = v.QF
      var SP = v.SP, TH = v.TH, ORB = v.ORB, YS = v.YS, PD = v.PD, PSP = v.PSP
      var WV = v.WV, WSP = v.WSP, DOF = v.DOF, RF = v.RF, DPH = v.DPH
      var CX = v.CX, CY = v.CY, offsetY = preset.offsetY

      var POINT_COUNT = 3600
      var STRIDE = 6000.0 / POINT_COUNT
      var alphaFaint = 0.27 * 0.84 * fade
      var alphaBright = 0.48 * 0.84 * fade
      var cos = Math.cos, sin = Math.sin, sqrt = Math.sqrt

      // Two passes (faint, then bright) so each only needs one fillStyle set —
      // cheap alpha grouping instead of per-point state changes.
      for (var pass = 0; pass < 2; pass++) {
        var bright = pass === 1
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, bright ? alphaBright : alphaFaint)
        for (var i = 0; i < POINT_COUNT; i++) {
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
          var size = big ? sizeLarge : sizeSmall
          ctx.fillRect(x - size / 2, py - size / 2, size, size)
        }
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
