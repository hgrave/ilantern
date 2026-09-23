// Pure helpers for the Zalo plugin. No QML types in here so the logic can be
// exercised with plain node (see tests/model.test.js).

var DEFAULT_URL = "https://chat.zalo.me/"
var DEFAULT_WINDOW_PATTERN = "chat\\.zalo\\.me|zalo"
var DEFAULT_BROWSER_PATTERN = "chromium|chrome|brave|edge|vivaldi|opera|helium|firefox|zen"
var DEFAULT_MATCH_HOST = "chat.zalo.me"
var DEFAULT_MAX_RECENT = 15

function stripFileUrl(url) {
  return decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
}

// A user-supplied regex that fails to compile must never take the widget down;
// fall back to the default pattern instead.
function safeRegex(pattern, fallback) {
  try {
    return new RegExp(String(pattern || fallback), "i")
  } catch (e) {
    return new RegExp(fallback, "i")
  }
}

function isZaloAppId(appId, pattern) {
  var id = String(appId || "")
  if (id === "") return false
  return safeRegex(pattern, DEFAULT_WINDOW_PATTERN).test(id)
}

// Zalo Web (and most chat web apps) prefix the document title with the unread
// count, e.g. "(3) Zalo". Returns 0 when the title carries no count.
function titleUnread(title) {
  var match = String(title || "").match(/^\s*\((\d+)\+?\)/)
  if (!match) return 0
  var n = parseInt(match[1], 10)
  return isFinite(n) && n > 0 ? n : 0
}

function decodeEntities(text) {
  return String(text || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, function(_, code) { return String.fromCharCode(parseInt(code, 10)) })
    .replace(/&amp;/g, "&")
}

// Chromium prefixes a web notification body with the page origin, either as a
// link (<a href="https://chat.zalo.me/">chat.zalo.me</a>) when the daemon
// supports body hyperlinks, or as a bare "chat.zalo.me" line. Strip that and
// any remaining markup so only the message preview is left.
function cleanBody(body, host) {
  var text = String(body || "")
  text = text.replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, "")
  text = text.replace(/<[^>]+>/g, "")
  text = decodeEntities(text)
  var lines = text.split(/\r?\n/)
  var kept = []
  var h = String(host || DEFAULT_MATCH_HOST).toLowerCase()
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (h !== "" && line.toLowerCase() === h) continue
    kept.push(line)
  }
  return kept.join(" ")
}

// Parses one line from bin/zalo-notify-watch: fields separated by \x1f
// (app, summary, body). Tabs/newlines were already flattened to "\n" escapes.
function parseWatcherLine(line) {
  var raw = String(line || "")
  if (raw === "") return null
  var parts = raw.split("\x1f")
  if (parts.length < 3) return null
  function unescape(s) { return s.replace(/\\n/g, "\n").replace(/\\\\/g, "\\") }
  return {
    app: unescape(parts[0]),
    summary: unescape(parts[1]),
    body: unescape(parts.slice(2).join("\x1f"))
  }
}

// Decides whether a raw notification came from Zalo: either a native client
// whose app name says Zalo, or a browser notification whose body carries the
// Zalo Web origin.
function isZaloNotification(note, options) {
  if (!note) return false
  var opts = options || {}
  var app = String(note.app || "")
  if (/zalo/i.test(app)) return true
  var host = String(opts.matchHost || DEFAULT_MATCH_HOST).toLowerCase()
  if (host === "" || String(note.body || "").toLowerCase().indexOf(host) === -1) return false
  return safeRegex(opts.browserPattern, DEFAULT_BROWSER_PATTERN).test(app)
}

function toMessage(note, host, nowMs) {
  var sender = String(note.summary || "").trim()
  var text = cleanBody(note.body, host)
  return {
    sender: sender !== "" ? sender : "Zalo",
    text: text,
    time: nowMs
  }
}

// Newest first, capped. Returns a fresh array so QML bindings notice.
function pushRecent(list, message, max) {
  var limit = Math.max(1, parseInt(max, 10) || DEFAULT_MAX_RECENT)
  var next = [message]
  var current = list instanceof Array ? list : []
  for (var i = 0; i < current.length && next.length < limit; i++) next.push(current[i])
  return next
}

function unreadCount(titleCount, notificationCount) {
  return Math.max(titleCount || 0, notificationCount || 0)
}

function badgeText(count) {
  if (!count || count <= 0) return ""
  return count > 99 ? "99+" : String(count)
}

function relativeTime(thenMs, nowMs) {
  var seconds = Math.max(0, Math.round((nowMs - thenMs) / 1000))
  if (seconds < 45) return "now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h"
  return Math.round(hours / 24) + "d"
}

function statusLine(running, unread) {
  if (!running && unread <= 0) return "Not running"
  if (unread <= 0) return "All caught up"
  return unread === 1 ? "1 unread message" : unread + " unread messages"
}

function tooltip(running, unread) {
  var line = statusLine(running, unread)
  return line === "Not running" ? "Zalo · click to open" : "Zalo · " + line
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_URL: DEFAULT_URL,
    DEFAULT_WINDOW_PATTERN: DEFAULT_WINDOW_PATTERN,
    DEFAULT_BROWSER_PATTERN: DEFAULT_BROWSER_PATTERN,
    DEFAULT_MATCH_HOST: DEFAULT_MATCH_HOST,
    DEFAULT_MAX_RECENT: DEFAULT_MAX_RECENT,
    stripFileUrl: stripFileUrl,
    safeRegex: safeRegex,
    isZaloAppId: isZaloAppId,
    titleUnread: titleUnread,
    cleanBody: cleanBody,
    parseWatcherLine: parseWatcherLine,
    isZaloNotification: isZaloNotification,
    toMessage: toMessage,
    pushRecent: pushRecent,
    unreadCount: unreadCount,
    badgeText: badgeText,
    relativeTime: relativeTime,
    statusLine: statusLine,
    tooltip: tooltip
  }
}
