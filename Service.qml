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

  // Trusted, absolute identities for every external command this service
  // runs, resolved once here rather than looked up by name (PATH) at
  // invocation time. Idle/lock/wake is a security-sensitive boundary — an
  // unqualified command name there is one a compromised PATH could
  // redirect, and a login shell (bash -l) sources profile/rc files that
  // could do the same. Every Process below uses these directly and, for
  // the lock/wake calls, no shell at all (they take no arguments and need
  // no shell features).
  readonly property string lockBin: "/usr/share/omarchy/bin/omarchy-system-lock"
  readonly property string wakeBin: "/usr/share/omarchy/bin/omarchy-system-wake"
  readonly property string bashBin: "/usr/bin/bash"
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

  // `argv` is a plain argument vector (executable first) run directly, with
  // no shell involved — see the comment on lockBin/wakeBin/bashBin above.
  function runProcess(process, label, argv) {
    if (process.running) {
      logEvent("process-skip", label + " already running")
      return false
    }
    logEvent("process-start", label + " " + argv.join(" "))
    process.command = argv
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
    runProcess(lockProcess, "lock", [root.lockBin])
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

    if (root.idledThisCycle) runProcess(wakeProcess, "wake", [root.wakeBin])

    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
  }

  function handleActiveSignal() {
    if (!root.idledThisCycle) return
    // Mapping our own screensaver surface can itself make the compositor's
    // idle monitor report "active" (the stock omarchy.idle service has the
    // exact same caveat, guarded with its own window-count/grace-timer
    // machinery). Real dismissal already comes straight from
    // ScreensaverView's own Keys/MouseArea handlers via the dismissed
    // signal below — so once the screensaver is actually up, an idle
    // monitor "active" ping is ignored rather than treated as a real
    // dismiss. Without this, a spurious ping would cancel the cycle, the
    // still-genuinely-idle user would trip idle detection again almost
    // immediately, and the *next* scene in the rotation would show —
    // which read as "the scene changed on its own mid-session".
    if (root.screensaverActive) {
      logEvent("idle-monitor-active", "screensaver shown, ignoring")
      return
    }
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

  // Non-login shell (-c, not -l — no profile/rc sourcing), absolute paths
  // for bash itself and every coreutils call inside it, and the directory
  // and file paths passed in as arguments rather than read from the
  // process's own $HOME (root.home already comes from Quickshell.env, not
  // the shell's inherited environment). Touches or removes the marker file
  // only when it is safe to: absent, or present as a *regular file we own,
  // not a symlink* (`-O` is bash's own effective-owner test) — so a symlink
  // planted at that exact path can't make this service follow it onto an
  // unrelated file.
  readonly property string stayAwakeWriteScript: '
set -e
dir="$1"; f="$2"; mode="$3"
/usr/bin/mkdir -p -- "$dir"
safe=0
if [ ! -e "$f" ]; then safe=1
elif [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then safe=1
fi
[ "$safe" = 1 ] || exit 0
if [ "$mode" = on ]; then /usr/bin/touch -- "$f"; else /usr/bin/rm -f -- "$f"; fi
'

  function persistStayAwake(value) {
    if (stayAwakeStateWriter.running) {
      root.pendingStayAwakePersist = !!value
      root.hasPendingStayAwakePersist = true
      return
    }

    stayAwakeStateWriter.command = [root.bashBin, "-c", root.stayAwakeWriteScript,
      "persist-stay-awake", root.stayAwakeStateDir, root.stayAwakeStatePath, value ? "on" : "off"]
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

  // Same hardening as stayAwakeWriteScript above: non-login shell, absolute
  // coreutils paths, explicit args instead of $HOME, and only reports "yes"
  // for a regular file we own that isn't a symlink — so a symlink planted
  // at that path can't force stay-awake on by being read as present.
  readonly property string stayAwakeProbeScript: '
set -e
dir="$1"; f="$2"
/usr/bin/mkdir -p -- "$dir"
if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then echo yes; else echo no; fi
'

  Process {
    id: stayAwakeStateProbe
    command: [root.bashBin, "-c", root.stayAwakeProbeScript,
      "stay-awake-probe", root.stayAwakeStateDir, root.stayAwakeStatePath]
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

    // Goes through startIdleCycle() itself — unlike preview(), this sets
    // idledThisCycle exactly like a real idle timeout would, so testing
    // handleActiveSignal()'s behaviour (which short-circuits on
    // idledThisCycle) actually exercises it. preview() alone cannot: it
    // never sets idledThisCycle, so handleActiveSignal() returns before
    // reaching anything worth testing.
    function simulateIdle(): string {
      root.startIdleCycle()
      return "ok"
    }

    // Triggers a real lock immediately, the same call lockTimer makes at
    // the real timeout — for verifying the lock process launches
    // correctly (exit code, etc.) without waiting out the real delay.
    function simulateLock(): string {
      root.lockSystem("test")
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
        onDismissed: function(reason) { root.cancelIdleCycle("screensaver-dismissed: " + reason) }
      }
    }
  }
}
