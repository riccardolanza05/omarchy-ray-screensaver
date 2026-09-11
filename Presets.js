// Verbatim parameters from plugins.omarchy.org's hero canvas (function
// setupHeroRay in assets/js/app.js). BASE are the site's defaults; each
// preset overrides a subset of them. Only three of the site's own six scenes
// are kept here (ORIGINAL, COCOON and STORM were dropped by request) — see
// the .reference/ dropped-presets.js file in this repo to restore them.
.pragma library

var BASE = {
  AMP: 4, WIND: 35, VS: 7, VO: 13, QA: 2, QF: 3, SP: 35, TH: 9,
  ORB: 40, YS: 35, PD: 9, PSP: 2, WV: 9, WSP: 2, DOF: 4,
  RF: 9, DPH: 2, CX: 200, CY: 0
}

var PRESETS = [
  {
    name: "RAY", zoom: 1.18, offsetY: 0,
    over: { AMP: 8.69, WIND: 38.26, VS: 16.38, VO: 11.75, QA: 1.65, QF: 3.47,
      SP: 38.62, TH: 9.63, ORB: 47.63, YS: 7.34, PD: 10.77, PSP: 2.73,
      WV: 7.21, WSP: 3.79, DOF: 5.98, RF: 3.04, DPH: 3.18, CX: 201, CY: 161 }
  },
  {
    name: "BIRD", zoom: 1.08, offsetY: 0,
    over: { AMP: 9.07, WIND: 73.68, VS: 15.45, VO: 25.38, QA: 4.98, QF: 5.32,
      SP: 44.61, TH: 9.37, ORB: 16.84, YS: 21.85, PD: 12.64, PSP: 3.52,
      WV: 10.31, WSP: 2, DOF: 3.3, RF: 10.2, DPH: 2.76, CX: 200, CY: -261 }
  },
  {
    name: "WING", zoom: 1.18, offsetY: 0,
    over: { AMP: 7.18, WIND: 47.39, VS: 16.24, VO: 28.23, QA: 3.58, QF: 5.84,
      SP: 38.57, TH: 12.2, ORB: 25.09, YS: 10.8, PD: 15.4, PSP: 3.23,
      WV: 12.94, WSP: 1.19, DOF: 8.59, RF: 10.94, DPH: 0.79, CX: 205, CY: -5 }
  }
]

function resolve(index) {
  var p = PRESETS[Math.max(0, Math.min(PRESETS.length - 1, index))]
  var values = {}
  for (var k in BASE) values[k] = BASE[k]
  for (var k2 in p.over) values[k2] = p.over[k2]
  return { name: p.name, zoom: p.zoom, offsetY: p.offsetY, values: values }
}

function indexByName(name, fallback) {
  var want = String(name || "").trim().toUpperCase()
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].name === want) return i
  return fallback === undefined ? 0 : fallback
}
