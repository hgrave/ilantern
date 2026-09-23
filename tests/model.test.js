// Run: node tests/model.test.js  (or ./tests/run.sh)
const assert = require("assert")
const { execFileSync } = require("child_process")
const fs = require("fs")
const path = require("path")
const M = require("../Model.js")

let passed = 0
function test(name, fn) {
  fn()
  passed++
  console.log("ok - " + name)
}

test("titleUnread reads a leading (N) count", () => {
  assert.strictEqual(M.titleUnread("(3) Zalo"), 3)
  assert.strictEqual(M.titleUnread("(99+) Zalo"), 99)
  assert.strictEqual(M.titleUnread("Zalo"), 0)
  assert.strictEqual(M.titleUnread("Zalo (3)"), 0)
  assert.strictEqual(M.titleUnread(null), 0)
})

test("isZaloAppId matches Chrome/Brave app windows and native clients", () => {
  assert.ok(M.isZaloAppId("chrome-chat.zalo.me__-Default", M.DEFAULT_WINDOW_PATTERN))
  assert.ok(M.isZaloAppId("brave-chat.zalo.me__-Profile_1", M.DEFAULT_WINDOW_PATTERN))
  assert.ok(M.isZaloAppId("Zalo", M.DEFAULT_WINDOW_PATTERN))
  assert.ok(!M.isZaloAppId("google-chrome", M.DEFAULT_WINDOW_PATTERN))
  assert.ok(!M.isZaloAppId("", M.DEFAULT_WINDOW_PATTERN))
  // A broken user regex falls back to the default instead of throwing.
  assert.ok(M.isZaloAppId("chrome-chat.zalo.me__-Default", "(("))
})

test("cleanBody strips the origin link, markup and entities", () => {
  assert.strictEqual(
    M.cleanBody('<a href="https://chat.zalo.me/">chat.zalo.me</a>\n\nHello <b>there</b>', "chat.zalo.me"),
    "Hello there")
  assert.strictEqual(M.cleanBody("chat.zalo.me\n\nA &amp; B &lt;3", "chat.zalo.me"), "A & B <3")
})

test("isZaloNotification accepts browser+host and native Zalo only", () => {
  const opts = { matchHost: "chat.zalo.me", browserPattern: M.DEFAULT_BROWSER_PATTERN }
  assert.ok(M.isZaloNotification({ app: "Google Chrome", body: "chat.zalo.me\nhi" }, opts))
  assert.ok(M.isZaloNotification({ app: "Brave", body: "<a href=\"https://chat.zalo.me/\">chat.zalo.me</a>" }, opts))
  assert.ok(M.isZaloNotification({ app: "Zalo", body: "hi" }, opts))
  assert.ok(!M.isZaloNotification({ app: "Slack", body: "chat.zalo.me" }, opts))
  assert.ok(!M.isZaloNotification({ app: "Google Chrome", body: "web.whatsapp.com" }, opts))
})

test("pushRecent keeps newest first and caps the list", () => {
  let list = []
  for (let i = 0; i < 5; i++) list = M.pushRecent(list, { n: i }, 3)
  assert.deepStrictEqual(list.map(m => m.n), [4, 3, 2])
})

test("badge, status and relative time text", () => {
  assert.strictEqual(M.badgeText(0), "")
  assert.strictEqual(M.badgeText(7), "7")
  assert.strictEqual(M.badgeText(150), "99+")
  assert.strictEqual(M.unreadCount(2, 5), 5)
  assert.strictEqual(M.statusLine(false, 0), "Not running")
  assert.strictEqual(M.statusLine(true, 0), "All caught up")
  assert.strictEqual(M.statusLine(true, 1), "1 unread message")
  assert.strictEqual(M.statusLine(false, 4), "4 unread messages")
  assert.strictEqual(M.relativeTime(0, 10 * 1000), "now")
  assert.strictEqual(M.relativeTime(0, 5 * 60 * 1000), "5m")
  assert.strictEqual(M.relativeTime(0, 3 * 3600 * 1000), "3h")
})

test("watcher parses dbus-monitor output end to end", () => {
  const root = path.join(__dirname, "..")
  const out = execFileSync(path.join(root, "bin/zalo-notify-watch"), ["--parse", "chat.zalo.me"], {
    input: fs.readFileSync(path.join(__dirname, "fixtures/dbus-monitor.txt"))
  }).toString()
  const notes = out.split("\n").filter(Boolean).map(M.parseWatcherLine)
  assert.strictEqual(notes.length, 3, "Slack notification must be filtered out by the watcher")
  const opts = { matchHost: "chat.zalo.me", browserPattern: M.DEFAULT_BROWSER_PATTERN }
  const msgs = notes.filter(n => M.isZaloNotification(n, opts)).map(n => M.toMessage(n, "chat.zalo.me", 0))
  assert.deepStrictEqual(msgs.map(m => [m.sender, m.text]), [
    ["Nguyễn Văn A", "Chào bạn, tối nay đi ăn không?"],
    ["Nhóm Gia Đình", "Mẹ: A & B đã về"],
    ["Trần B", "single line"]
  ])
})

console.log(`\n${passed} passed`)
