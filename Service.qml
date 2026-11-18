import QtQuick
import Quickshell
import Quickshell.Io

// NextDNS state for the bar and panel. probe.py does the talking; this file
// schedules it, parses its one JSON line, and runs start/stop through pkexec
// (the shell has no terminal to ask for a sudo password).
Item {
  id: root
  visible: false

  property var settings: ({})
  property string pluginDir: ""

  property bool loaded: false
  property bool installed: true
  property bool running: false
  property string profile: ""
  property string listen: ""

  // Result of the test.nextdns.io check; netChecked stays false until one ran.
  property bool netChecked: false
  property bool netReachable: false
  property bool usingNextDns: false
  property string protocol: ""
  property string server: ""
  property string clientIp: ""
  property string device: ""

  // Last 24 h of analytics from the NextDNS API (needs an API key file).
  // statsState: idle | nokey | noprofile | auth | error | ok
  property string statsState: "idle"
  property real statsTotal: 0
  property real statsBlocked: 0
  property var statsSeries: []   // [[total, blocked], …] one per hour, oldest first
  property var statsTop: []      // [{ domain, queries }, …] most blocked first
  property double statsAt: 0
  readonly property real blockedShare: statsTotal > 0 ? statsBlocked / statsTotal : 0

  // API key entry from the panel: keyError is a translation key or "".
  readonly property bool keySaving: keyProcess.running
  property string keyError: ""
  property string _pendingKey: ""

  // Translation key of the last failure, "" when fine.
  property string lastError: ""

  // Optimistic switch state: -1 follows reality, 0/1 while a start/stop settles.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : _desired === 1
  readonly property bool busy: controlProcess.running
  readonly property bool refreshing: probeProcess.running

  // protected | unencrypted | leaking | offline | stopped | missing | loading
  readonly property string state: {
    if (!loaded) return "loading"
    if (!installed) return "missing"
    if (!running) return "stopped"
    if (!netChecked) return "protected"
    if (!netReachable) return "offline"
    if (!usingNextDns) return "leaking"
    if (protocol !== "" && protocol.indexOf("DO") !== 0) return "unencrypted"
    return "protected"
  }
  readonly property string dashboardUrl: "https://my.nextdns.io/" + (profile !== "" ? profile + "/" : "")

  readonly property string cliPath: String(setting("cliPath", "nextdns")) || "nextdns"
  readonly property bool checkConnection: setting("checkConnection", true) === true
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 600)
  readonly property string apiKeyFile: String(setting("apiKeyFile", "~/.config/nextdns/api-key")) || "~/.config/nextdns/api-key"

  property string _output: ""
  property bool _queuedNet: false
  property bool _queuedStats: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // withNet adds the test.nextdns.io round trip and withStats the API calls;
  // local checks are free. Stats younger than a minute are reused unless forced.
  function refresh(withNet, withStats, force) {
    var net = withNet === true && checkConnection
    var stats = withStats === true && (force === true || Date.now() - statsAt > 60000)
    if (probeProcess.running) {
      _queuedNet = _queuedNet || net
      _queuedStats = _queuedStats || stats
      return
    }
    _output = ""
    var command = ["python3", "-I", pluginDir + "/probe.py", cliPath]
    if (net) command.push("--net")
    if (stats) command.push("--stats", apiKeyFile.replace(/^~(?=\/)/, Quickshell.env("HOME")))
    probeProcess.command = command
    probeProcess.running = true
  }

  function apply(raw) {
    var data
    try { data = JSON.parse(String(raw || "").trim()) } catch (e) { data = null }
    if (!data || data.ok !== true) {
      lastError = "error.status"
      return
    }
    loaded = true
    installed = data.installed === true
    running = data.running === true
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    profile = String(data.profile || "")
    listen = String(data.listen || "")
    if (data.net) {
      netChecked = true
      netReachable = data.net.reachable === true
      usingNextDns = data.net.using === true
      protocol = String(data.net.protocol || "")
      server = String(data.net.server || "")
      clientIp = String(data.net.clientIp || "")
      device = String(data.net.device || "")
    } else if (!running) {
      netChecked = false
    }
    if (data.stats) applyStats(data.stats)
    lastError = ""
  }

  function applyStats(stats) {
    statsState = String(stats.state || "error")
    if (statsState !== "ok") return
    statsAt = Date.now()
    statsTotal = Number(stats.total) || 0
    statsBlocked = Number(stats.blocked) || 0
    statsSeries = Array.isArray(stats.series) ? stats.series.slice(0, 48) : []
    statsTop = Array.isArray(stats.top) ? stats.top.slice(0, 5) : []
  }

  function saveKey(key) {
    var value = String(key || "").trim()
    if (keyProcess.running) return
    if (!/^[A-Za-z0-9]{16,128}$/.test(value)) {
      keyError = "key.invalid"
      return
    }
    keyError = ""
    _pendingKey = value
    keyProcess.command = ["python3", "-I", pluginDir + "/probe.py", "--save-key",
                          apiKeyFile.replace(/^~(?=\/)/, Quickshell.env("HOME"))]
    keyProcess.running = true
  }

  function setActive(on) {
    if (!installed || busy) return
    _desired = on ? 1 : 0
    lastError = ""
    controlProcess.command = ["pkexec", cliPath, on ? "start" : "stop"]
    controlProcess.running = true
  }

  function restart() {
    if (!installed || busy) return
    _desired = 1
    controlProcess.command = ["pkexec", cliPath, "restart"]
    controlProcess.running = true
  }

  function openUrl(url) {
    Quickshell.execDetached(["xdg-open", url])
  }

  Component.onCompleted: refresh(true)

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    property int ticks: 0
    // Re-test the real path every ~5 minutes; local status every tick.
    onTriggered: {
      ticks += 1
      root.refresh(ticks % Math.max(1, Math.round(300 / root.refreshIntervalSec)) === 0)
    }
  }

  // The daemon needs a moment to come up or go down before status is truthful.
  Timer {
    id: settle
    interval: 1200
    onTriggered: root.refresh(true)
  }

  Process {
    id: probeProcess
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        if (root._output.length < 32768) root._output += data
      }
    }
    onExited: {
      root.apply(root._output)
      if (root._queuedNet || root._queuedStats) {
        var net = root._queuedNet, stats = root._queuedStats
        root._queuedNet = false
        root._queuedStats = false
        Qt.callLater(function() { root.refresh(net, stats, true) })
      }
    }
  }

  // Writes the key to the helper's stdin, then closes it so the helper reads EOF.
  Process {
    id: keyProcess
    stdinEnabled: true
    stdout: StdioCollector { id: keyOutput }
    onStarted: {
      write(root._pendingKey + "\n")
      root._pendingKey = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      var result
      try { result = JSON.parse(String(keyOutput.text || "").trim()) } catch (e) { result = null }
      if (!result || result.ok !== true) {
        root.keyError = result && result.error === "invalid" ? "key.invalid" : "key.writeFailed"
        return
      }
      root.statsState = "idle"
      root.statsAt = 0
      root.refresh(false, true, true)
    }
  }

  Process {
    id: controlProcess
    stderr: StdioCollector { id: controlErrors }
    onExited: function(exitCode) {
      // 126/127 from pkexec: the auth dialog was dismissed or refused.
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = exitCode === 126 || exitCode === 127
          ? "error.cancelled"
          : "error.control"
      }
      settle.restart()
    }
  }
}
