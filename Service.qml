import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// One instance per shell (not per monitor): owns the notification watcher,
// the unread count, the recent-message list, and everything that touches the
// Zalo window. The bar widget on each monitor binds to this through
// shell.serviceFor(), so marking messages read on one screen clears the badge
// everywhere.
//
// Zalo Web runs as a Chromium-family --app window in the user's own browser
// profile (see bin/zalo-launch), so extensions from that profile — such as an
// auto-translate extension — keep working inside it.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.hgrave.zalo"
  readonly property string watcherPath: Model.stripFileUrl(Qt.resolvedUrl("bin/zalo-notify-watch"))
  readonly property string launcherPath: Model.stripFileUrl(Qt.resolvedUrl("bin/zalo-launch"))

  // Pushed in by the bar widget from its shell.json entry (configure()).
  property string url: Model.DEFAULT_URL
  property string browser: "default"
  property string profile: ""
  property string windowPattern: Model.DEFAULT_WINDOW_PATTERN
  property string browserPattern: Model.DEFAULT_BROWSER_PATTERN
  property int maxRecent: Model.DEFAULT_MAX_RECENT
  readonly property string matchHost: hostOf(url)

  // State.
  property var toplevel: null
  readonly property bool running: toplevel !== null
  readonly property bool focused: toplevel !== null && toplevel.activated
  readonly property int titleCount: toplevel ? Model.titleUnread(toplevel.title) : 0
  property int notificationCount: 0
  readonly property int unread: Model.unreadCount(titleCount, notificationCount)
  property var recent: []
  property real lastSeen: 0
  property string lastError: ""
  property bool launching: launchGuard.running

  signal messageArrived(var message)

  function hostOf(value) {
    var m = String(value || "").match(/^[a-z]+:\/\/([^\/?#]+)/i)
    return m ? m[1].toLowerCase() : Model.DEFAULT_MATCH_HOST
  }

  function configure(settings) {
    var s = settings || {}
    function str(key, fallback) {
      var v = s[key]
      return v === undefined || v === null || String(v).trim() === "" ? fallback : String(v).trim()
    }
    url = str("url", Model.DEFAULT_URL)
    browser = browserKey(str("browser", "Default browser"))
    profile = str("profile", "")
    windowPattern = str("windowClassPattern", Model.DEFAULT_WINDOW_PATTERN)
    var max = parseInt(s.maxRecent, 10)
    maxRecent = isFinite(max) && max > 0 ? max : Model.DEFAULT_MAX_RECENT
    refreshWindow()
  }

  function browserKey(label) {
    var l = String(label).toLowerCase()
    if (l.indexOf("chrome") === 0 || l === "google chrome") return "chrome"
    if (l.indexOf("brave") === 0) return "brave"
    if (l.indexOf("chromium") === 0) return "chromium"
    if (l.indexOf("default") === 0) return "default"
    return label
  }

  function findToplevel() {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      if (Model.isZaloAppId(list[i].appId, root.windowPattern)) return list[i]
    }
    return null
  }

  function refreshWindow() {
    toplevel = findToplevel()
    if (focused) markRead()
  }

  function markRead() {
    notificationCount = 0
    lastSeen = Date.now()
  }

  function clearRecent() {
    recent = []
    markRead()
  }

  // Focus the Zalo window if it exists, otherwise launch it. Returns "focused",
  // "launching", or "busy" (a launch is already in flight).
  function focusOrLaunch() {
    var t = findToplevel()
    if (t) {
      t.activate()
      markRead()
      return "focused"
    }
    if (launchGuard.running) return "busy"
    lastError = ""
    launchGuard.restart()
    launchProcess.command = [root.launcherPath, root.browser, root.url, root.profile]
    launchProcess.running = true
    return "launching"
  }

  function closeWindow() {
    var t = findToplevel()
    if (!t) return "not-running"
    t.close()
    return "closed"
  }

  function statusJson() {
    return JSON.stringify({
      running: running,
      focused: focused,
      unread: unread,
      browser: browser,
      profile: profile,
      url: url,
      recent: recent.length
    })
  }

  function handleNotification(note) {
    if (!Model.isZaloNotification(note, { matchHost: root.matchHost, browserPattern: root.browserPattern })) return
    var message = Model.toMessage(note, root.matchHost, Date.now())
    recent = Model.pushRecent(recent, message, maxRecent)
    // Zalo still notifies while you are looking at it in some cases; only count
    // what arrives while the window is not focused.
    if (!focused) notificationCount = notificationCount + 1
    messageArrived(message)
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.refreshWindow() }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.refreshWindow() }
  }

  Connections {
    target: root.toplevel
    ignoreUnknownSignals: true
    function onActivatedChanged() { if (root.focused) root.markRead() }
  }

  // A new window takes a moment to appear as a toplevel; without the guard a
  // double click would open two Zalo windows.
  Timer {
    id: launchGuard
    interval: 8000
  }

  Process {
    id: launchProcess
    stderr: StdioCollector { id: launchErr }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      root.lastError = String(launchErr.text || "").trim() || ("Launching Zalo failed (exit " + exitCode + ")")
      launchGuard.stop()
    }
  }

  Process {
    id: watcher
    command: [root.watcherPath, root.matchHost]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        var note = Model.parseWatcherLine(line)
        if (note) root.handleNotification(note)
      }
    }
    // The watcher should live as long as the shell. If it dies (bus hiccup),
    // bring it back after a short pause instead of silently going stale.
    onExited: {
      if (root.watcherRestarting) {
        root.watcherRestarting = false
        watcher.running = true
      } else {
        restartWatcher.restart()
      }
    }
  }

  Timer {
    id: restartWatcher
    interval: 5000
    onTriggered: if (!watcher.running) watcher.running = true
  }

  // Restart the watcher when the Zalo host changes, since the host is baked
  // into its command line.
  property bool watcherRestarting: false
  onMatchHostChanged: {
    if (!watcher.running) return
    watcherRestarting = true
    watcher.running = false
  }

  // omarchy-shell zalo <method>
  IpcHandler {
    target: "zalo"

    function open(): string { return root.focusOrLaunch() }
    function focus(): string { return root.focusOrLaunch() }
    function close(): string { return root.closeWindow() }
    function markRead(): string { root.markRead(); return "ok" }
    function clear(): string { root.clearRecent(); return "ok" }
    function unread(): string { return String(root.unread) }
    function status(): string { return root.statusJson() }
  }

  Component.onCompleted: refreshWindow()
}
