import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Presets.js" as Presets

// Clone of Omarchy's stock idle service (omarchy.idle — see manifest.json's
// "clonedFrom"). Idle timing, the lock timer, and stay-awake are unchanged;
// the only difference is *what plays* at the screensaver timeout: one
// in-process QML scene per activation (see ScreensaverView.qml and
// Presets.js) instead of the stock terminal-based
// omarchy-launch-screensaver. Because the screensaver is now rendered
// inside this same plugin instead of spawned as an external process, there
// is no window-class tracking to do: showing and hiding it is a single
// property flip.
Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stayAwakeStateDir: home + "/.local/state/omarchy/indicators"
  readonly property string stayAwakeStatePath: stayAwakeStateDir + "/stay-awake"
  readonly property int defaultScreensaverSeconds: 150
  readonly property int defaultLockSeconds: 300
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : (shell && shell.idleConfig ? shell.idleConfig : ({}))
  readonly property int screensaverTimeoutSeconds: secondsFromConfig(idleConfig.screensaver, defaultScreensaverSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(idleConfig.lock, defaultLockSeconds)
  readonly property int firstIdleTimeoutSeconds: Math.min(screensaverTimeoutSeconds, lockTimeoutSeconds)
  readonly property int screensaverDelaySeconds: Math.max(0, screensaverTimeoutSeconds - firstIdleTimeoutSeconds)
  readonly property int lockDelaySeconds: Math.max(0, lockTimeoutSeconds - firstIdleTimeoutSeconds)
  readonly property bool idleEnabled: stayAwakeStateLoaded && !stayAwake

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property bool hasPendingStayAwakePersist: false
  property bool pendingStayAwakePersist: false
  property bool idledThisCycle: false
  property bool screensaverStartedThisCycle: false
  property string lastEvent: "starting"
  property string lastEventAt: ""

  // Rotates one step through every scene in Presets.js each time the
  // screensaver is shown — one scene per activation, unlocking (or any
  // other dismiss) makes it go away, and the *next* activation is a
  // different scene, cycling through all of them before repeating. Starts
  // one step before the first entry so the very first launch of a shell
  // session lands on scene 0.
  property int screensaverPresetIndex: Presets.PRESETS.length - 1
  property bool screensaverActive: false

  function secondsFromConfig(value, fallback) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return fallback
    return Math.floor(n)
  }

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("omarchy-ray-screensaver " + root.lastEventAt + " " + root.lastEvent)
  }

  function runProcess(process, label, command) {
    if (process.running) {
      logEvent("process-skip", label + " already running")
      return false
    }
    logEvent("process-start", label + " " + command)
    process.command = ["bash", "-lc", command]
    process.running = true
    return true
  }

  function launchScreensaver() {
    root.screensaverStartedThisCycle = true
    root.screensaverPresetIndex = (root.screensaverPresetIndex + 1) % Presets.PRESETS.length
    root.screensaverActive = true
    logEvent("screensaver-shown", "preset=" + root.screensaverPresetIndex)
  }

  // Shows an arbitrary preset index without touching the rotation counter
  // above — for jumping straight to one scene (testing, or a menu entry)
  // without disturbing where the rotation itself is.
  function launchScreensaverAt(idx) {
    root.screensaverStartedThisCycle = true
    root.screensaverPresetIndex = idx
    root.screensaverActive = true
    logEvent("screensaver-shown", "preset=" + idx + " (pinned)")
  }

  function hideScreensaver(reason) {
    if (!root.screensaverActive) return
    root.screensaverActive = false
    logEvent("screensaver-hidden", reason || "")
  }

  function lockSystem(reason) {
    logEvent("lock-system", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    hideScreensaver("locking")
    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
    runProcess(lockProcess, "lock", "omarchy-system-lock")
  }

  function startIdleCycle() {
    if (root.idledThisCycle) {
      logEvent("idle-cycle-already-running")
      return
    }

    logEvent("idle-cycle-start", "screensaver=" + root.screensaverTimeoutSeconds + " lock=" + root.lockTimeoutSeconds)
    root.idledThisCycle = true
    root.screensaverStartedThisCycle = false

    if (root.screensaverDelaySeconds === 0) launchScreensaver()
    else screensaverTimer.restart()

    if (root.lockDelaySeconds === 0) lockSystem("lock-timeout-immediate")
    else lockTimer.restart()
  }

  function cancelIdleCycle(reason) {
    logEvent("idle-cycle-cancel", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    hideScreensaver(reason)

    if (root.idledThisCycle) runProcess(wakeProcess, "wake", "omarchy-system-wake")

    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
  }

  function handleActiveSignal() {
    if (!root.idledThisCycle) return
    cancelIdleCycle("activity")
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", idleMonitor.isIdle ? "idle" : "active")
    if (!root.idleEnabled) return

    if (idleMonitor.isIdle) startIdleCycle()
    else handleActiveSignal()
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.idleEnabled,
      stayAwake: root.stayAwake,
      stayAwakeStateLoaded: root.stayAwakeStateLoaded,
      idle: idleMonitor.isIdle,
      inIdleCycle: root.idledThisCycle,
      screensaverActive: root.screensaverActive,
      screensaverPreset: root.screensaverPresetIndex,
      screensaver: root.screensaverTimeoutSeconds,
      lock: root.lockTimeoutSeconds,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  function persistStayAwake(value) {
    var command = value
      ? "mkdir -p \"$HOME/.local/state/omarchy/indicators\" && touch \"$HOME/.local/state/omarchy/indicators/stay-awake\""
      : "rm -f \"$HOME/.local/state/omarchy/indicators/stay-awake\""

    if (stayAwakeStateWriter.running) {
      root.pendingStayAwakePersist = !!value
      root.hasPendingStayAwakePersist = true
      return
    }

    stayAwakeStateWriter.command = ["bash", "-lc", command]
    stayAwakeStateWriter.running = true
  }

  function refreshStayAwakeState() {
    if (!stayAwakeStateProbe.running) stayAwakeStateProbe.running = true
  }

  function applyStayAwake(value, persist, reason) {
    var enabled = !!value
    var changed = !root.stayAwakeStateLoaded || root.stayAwake !== enabled

    if (persist) persistStayAwake(enabled)

    root.stayAwake = enabled
    root.stayAwakeStateLoaded = true

    if (!changed) return enabled ? "disabled" : "enabled"

    logEvent("stay-awake", (enabled ? "enabled" : "disabled") + (reason ? " " + reason : ""))
    if (enabled) cancelIdleCycle("stay-awake")
    else Qt.callLater(root.handleIdleChanged)

    return enabled ? "disabled" : "enabled"
  }

  function setIdleEnabled(value) {
    return applyStayAwake(!value, true, "ipc")
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.idleEnabled
    timeout: root.firstIdleTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: root.handleIdleChanged()
  }

  Timer {
    id: screensaverTimer
    interval: root.screensaverDelaySeconds * 1000
    repeat: false
    onTriggered: root.launchScreensaver()
  }

  Timer {
    id: lockTimer
    interval: root.lockDelaySeconds * 1000
    repeat: false
    onTriggered: if (root.idleEnabled && root.idledThisCycle) root.lockSystem("lock-timeout")
  }

  Process {
    id: lockProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "lock exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: wakeProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "wake exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: stayAwakeStateProbe
    command: ["bash", "-c", "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; if [[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyStayAwake(String(line).trim() === "yes", false, "state-file") }
    }
    onExited: function() { stayAwakeStateDirWatcher.reload() }
  }

  Process {
    id: stayAwakeStateWriter
    onExited: function() {
      if (root.hasPendingStayAwakePersist) {
        var pending = root.pendingStayAwakePersist
        root.hasPendingStayAwakePersist = false
        root.persistStayAwake(pending)
        return
      }

      root.refreshStayAwakeState()
    }
  }

  FileView {
    id: stayAwakeStateDirWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  Component.onCompleted: {
    logEvent("service-ready")
    refreshStayAwakeState()
  }

  IpcHandler {
    target: "ray-screensaver"

    function status(): string {
      return root.statusJson()
    }

    function enable(): string {
      return root.setIdleEnabled(true)
    }

    function disable(): string {
      return root.setIdleEnabled(false)
    }

    function toggle(): string {
      return root.setIdleEnabled(!root.idleEnabled)
    }

    // Shows the screensaver right now, bypassing the idle timers — handy for
    // a menu entry or a keybinding, same spirit as System > Screensaver.
    function preview(): string {
      root.launchScreensaver()
      return "ok"
    }

    // Shows preset index N directly — for trying out scenes beyond the
    // three in the RAY/BIRD/WING rotation (see Presets.js) without
    // disturbing that rotation's own counter.
    function previewIndex(idx: string): string {
      var n = parseInt(idx, 10)
      if (isNaN(n) || n < 0) return "bad-index"
      root.launchScreensaverAt(n)
      return "ok"
    }
  }

  // One fullscreen surface per monitor. Only one needs keyboard focus to
  // catch a dismiss keypress; every one of them dismisses on its own mouse
  // movement or click regardless of which has focus.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: root.screensaverActive
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      WlrLayershell.namespace: "omarchy-ray-screensaver"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
      exclusionMode: ExclusionMode.Ignore

      ScreensaverView {
        anchors.fill: parent
        active: root.screensaverActive
        presetIndex: root.screensaverPresetIndex
        onDismissed: root.cancelIdleCycle("screensaver-dismissed")
      }
    }
  }
}
