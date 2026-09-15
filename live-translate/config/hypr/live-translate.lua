-- Live Translate - Hyprland drop-in for Omarchy 4 (Lua config).
-- Installed to ~/.config/hypr/live-translate.lua and loaded from hyprland.lua via
--   require("hypr.live-translate")
-- install.sh substitutes the absolute path of continuous_translate.sh below.

o.window({ title = "^(Live Translate)$" }, {
  float = true,
  pin = true,
  size = { 450, 350 },
  move = { "100%-470", "50" },
})

-- Toggle the pipeline (opens the window, or stops the running one).
o.bind("SUPER + SHIFT + T", "Live Translate", "@@SCRIPT@@ toggle")
