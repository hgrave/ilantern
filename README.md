# Zalo for Omarchy

An [Omarchy](https://omarchy.org) shell plugin for **Zalo**:

- **Bar icon with an unread badge.** The icon is dimmed while Zalo is closed.
- **One click opens or focuses Zalo.** Zalo Web (`chat.zalo.me`) opens as an app window in **your own Chrome, Brave or Chromium profile**. That means your extensions run inside Zalo, including auto-translate extensions.
- **Popup (right-click)** with Open/Show, Mark all as read, Close Zalo, and a list of recent messages (sender, preview and time).
- **Middle-click** marks everything as read.
- **CLI / keybinding control** through `omarchy-shell zalo …`.

## Install

```bash
omarchy plugin add https://github.com/hgrave/ilantern.git --enable
```

The installer places the widget in the right section of the bar by default. You can move it with `omarchy bar move io.github.hgrave.zalo --section left`.

Remove it with `omarchy plugin remove io.github.hgrave.zalo`.

## Using your translate extension (Chrome / Brave)

Pick the browser and profile that have the extension installed. In the bar, open the widget settings, or add the options inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.hgrave.zalo", "browser": "Brave", "profile": "Default" }
```

- `browser`: `Default browser`, `Google Chrome`, `Brave` or `Chromium`.
- `profile`: the profile *directory* name, e.g. `Default` or `Profile 1`. To find it, open `chrome://version` or `brave://version` and look at the last folder in "Profile Path". Leave it empty to use the last-used profile.

Zalo opens with `--app=https://chat.zalo.me/` in that profile. It is a real browser window without the toolbar, so the profile's extensions, logins and cookies all apply. A few tips:

- App windows hide the extension toolbar. Set the translate extension to **always translate** (or pick the target language) from a normal browser tab once. The setting then applies inside the Zalo window too. You can also right-click inside the page to reach the extension's context-menu entries.
- Chrome's built-in *Translate* also works in app windows: right-click → *Translate to …*.
- The previews in this plugin's popup come from Zalo's desktop notifications, so they show the **original** text, not the translation.
- Allow notifications for `chat.zalo.me` in the browser. The unread badge and the recent-messages list depend on them.

## How unread tracking works

Zalo has no public API for personal accounts, and Zalo Web keeps its unread state inside the browser tab. The plugin combines two signals:

1. **Desktop notifications.** `bin/zalo-notify-watch` runs `dbus-monitor` to observe `org.freedesktop.Notifications.Notify` calls on your session bus. It keeps only notifications that mention `chat.zalo.me`, or whose app name is Zalo (for native/unofficial clients). Each one counts as unread until you focus the Zalo window.
2. **The window title.** If the title starts with a count such as `(3) Zalo`, that count is used when it is higher.

The badge clears when the Zalo window gets focus, when you click the icon, or when you middle-click. Messages you read on your phone are not tracked.

Zalo has to be open (the window can sit on another workspace) for notifications to arrive. Nothing launches automatically at login. To start Zalo on login, add this to `~/.config/hypr/autostart.lua`:

```lua
-- use the same browser/profile you set in the widget
o.exec_on_start("~/.config/omarchy/plugins/io.github.hgrave.zalo/bin/zalo-launch brave https://chat.zalo.me/ Default")
```

## Keybindings and CLI

```bash
omarchy-shell zalo focus       # open Zalo, or focus it if it's already open
omarchy-shell zalo close       # close the Zalo window
omarchy-shell zalo markRead    # clear the badge
omarchy-shell zalo clear       # clear the recent-messages list
omarchy-shell zalo unread      # print the unread count
omarchy-shell zalo status      # JSON status
omarchy-shell zalo.panel toggle
```

Example binding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + Z", "Zalo", "omarchy-shell zalo focus")
```

Popup keys: ↑/↓ move, Enter runs the selection, `o` opens Zalo, `r` marks read, `c` clears the list, `q` closes Zalo, Esc closes the popup.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `browser` | `Default browser` | `Default browser`, `Google Chrome`, `Brave`, `Chromium` |
| `profile` | *(empty)* | Browser profile directory, e.g. `Profile 1` |
| `clickAction` | `Open or focus Zalo` | What left click does; right click does the other (`Open panel`) |
| `showCount` | `true` | Number badge; `false` shows a dot |
| `showPreviews` | `true` | Show message text in the popup |
| `maxRecent` | `15` | Recent messages kept (in memory only) |
| `url` | `https://chat.zalo.me/` | Zalo Web URL |
| `windowClassPattern` | `chat\.zalo\.me\|zalo` | Regex matched against the window class to find Zalo |

## Permissions and privacy

Omarchy plugins run **unsandboxed inside `omarchy-shell`** with your user's permissions. This plugin:

- Runs `dbus-monitor` as a session-bus monitor. That process sees *every* `Notify` call, because D-Bus offers no narrower subscription. The awk filter in `bin/zalo-notify-watch` drops everything that isn't Zalo before it reaches the shell.
- Keeps message previews **in memory only**. Nothing is written to disk and nothing is sent over the network.
- Launches your browser only when you ask it to (click, keybinding or IPC).

Dependencies: `dbus` (`dbus-monitor`) and a Chromium-based browser. Both ship with Omarchy.

## Development

```bash
./tests/run.sh                          # unit + parser tests (needs node)
omarchy plugin validate .
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.hgrave.zalo   # or copy it
omarchy-shell shell rescanPlugins && omarchy plugin enable io.github.hgrave.zalo
```

Saving files under `~/.config/omarchy/plugins/` hot-reloads the plugin.

## License

MIT
