#!/usr/bin/env bash
# install.sh - set up Live Translate on Arch Linux / Omarchy (Hyprland + PipeWire).
#
#   ./install.sh                 full install (packages, whisper.cpp, models, RNNoise, script, Hyprland)
#   ./install.sh --no-packages   skip pacman/yay (everything else)
#   ./install.sh --no-hypr       skip Hyprland config changes
#   ./install.sh --no-pipewire   skip RNNoise PipeWire filter-chain
#   ./install.sh --models "base small"   which ggml models to fetch (default: base small)
#   ./install.sh --set-default-source    make the RNNoise source the system default mic
#   ./install.sh --dry-run       print what would be done
#
# Idempotent: re-running updates the script and configs without duplicating lines.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="${LT_BIN_DIR:-$HOME/.local/bin}"
MODEL_DIR="${LT_MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/whisper/models}"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
PW_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
SRC_DIR="${LT_SRC_DIR:-$HOME/.local/src}"
MODEL_BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

DO_PACKAGES=1 DO_HYPR=1 DO_PIPEWIRE=1 DRY=0 SET_DEFAULT_SOURCE=0
MODELS="base small"
while (($#)); do
  case "$1" in
    --no-packages) DO_PACKAGES=0 ;;
    --no-hypr) DO_HYPR=0 ;;
    --no-pipewire) DO_PIPEWIRE=0 ;;
    --models) MODELS="$2"; shift ;;
    --set-default-source) SET_DEFAULT_SOURCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if ((DRY)); then printf '    [dry] %s\n' "$*"; else "$@"; fi; }

# Append a line to a file only if it is not already there.
ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then return 0; fi
  say "adding to $file: $line"
  if ((DRY)); then return 0; fi
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" && -s "$file" && "$(tail -c1 "$file")" != "" ]] && printf '\n' >>"$file"
  printf '%s\n' "$line" >>"$file"
}

# ---------------------------------------------------------------------------
# 1. Audio audit
# ---------------------------------------------------------------------------
say "Audio audit (PipeWire)"
if have wpctl; then
  wpctl status 2>/dev/null | sed -n '/Sources:/,/^ *$/p' | sed 's/^/    /' || true
elif have pactl; then
  pactl list short sources 2>/dev/null | sed 's/^/    /' || true
else
  warn "neither wpctl nor pactl found; is PipeWire running?"
fi
if have pactl; then echo "    default source: $(pactl get-default-source 2>/dev/null || echo '?')"; fi

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
if ((DO_PACKAGES)); then
  have pacman || { warn "pacman not found; this installer targets Arch/Omarchy. Use --no-packages."; exit 1; }
  say "Installing packages: sox, noise-suppression-for-voice, jq, libnotify, curl, cmake, base-devel"
  run sudo pacman -S --needed --noconfirm sox noise-suppression-for-voice jq libnotify curl cmake base-devel git

  if have whisper-cli || have whisper-cpp; then
    say "whisper.cpp already installed: $(command -v whisper-cli || command -v whisper-cpp)"
  else
    installed=0
    if pacman -Si whisper.cpp >/dev/null 2>&1; then
      say "Installing whisper.cpp from the official repos"
      run sudo pacman -S --needed --noconfirm whisper.cpp && installed=1
    fi
    if ((!installed)) && have yay; then
      for pkg in whisper.cpp whisper-cpp-git whisper.cpp-git; do
        say "Trying AUR package $pkg via yay"
        if run yay -S --needed --noconfirm "$pkg"; then installed=1; break; fi
      done
    fi
    if ((!installed)); then
      say "Building whisper.cpp from source into $BIN_DIR (static whisper-cli, native CPU flags: AVX2/FMA/F16C, AVX-512 on 11th gen)"
      run mkdir -p "$SRC_DIR" "$BIN_DIR"
      if [[ -d "$SRC_DIR/whisper.cpp/.git" ]]; then
        run git -C "$SRC_DIR/whisper.cpp" pull --ff-only
      else
        run git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$SRC_DIR/whisper.cpp"
      fi
      if ((!DRY)); then
        cd "$SRC_DIR/whisper.cpp"
        if ! cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=ON \
             -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON >/dev/null; then
          warn "native build configure failed; falling back to explicit AVX2 flags"
          cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
            -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON >/dev/null
        fi
        cmake --build build -j"$(nproc)" --config Release --target whisper-cli
        install -m755 build/bin/whisper-cli "$BIN_DIR/whisper-cli"
        cd "$HERE"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. Models
# ---------------------------------------------------------------------------
say "Whisper models -> $MODEL_DIR ($MODELS)"
run mkdir -p "$MODEL_DIR"
for m in $MODELS; do
  f="$MODEL_DIR/ggml-$m.bin"
  if [[ -s "$f" ]]; then echo "    ggml-$m.bin present"; continue; fi
  say "Downloading ggml-$m.bin"
  run curl -L --fail --progress-bar -o "$f.part" "$MODEL_BASE_URL/ggml-$m.bin"
  run mv "$f.part" "$f"
done

# ---------------------------------------------------------------------------
# 4. Script
# ---------------------------------------------------------------------------
say "Installing $BIN_DIR/continuous_translate.sh"
run mkdir -p "$BIN_DIR"
run install -m755 "$HERE/bin/continuous_translate.sh" "$BIN_DIR/continuous_translate.sh"
SCRIPT="$BIN_DIR/continuous_translate.sh"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on PATH (the keybind uses the absolute path, so this is fine)";; esac

# ---------------------------------------------------------------------------
# 5. RNNoise (PipeWire filter-chain)
# ---------------------------------------------------------------------------
if ((DO_PIPEWIRE)); then
  say "RNNoise PipeWire filter-chain -> $PW_DIR/99-input-denoising.conf"
  if [[ ! -e /usr/lib/ladspa/librnnoise_ladspa.so ]]; then
    warn "/usr/lib/ladspa/librnnoise_ladspa.so not found (package noise-suppression-for-voice). Installing config anyway."
  fi
  run mkdir -p "$PW_DIR"
  run install -m644 "$HERE/config/pipewire/99-input-denoising.conf" "$PW_DIR/99-input-denoising.conf"
  if have systemctl && systemctl --user is-active pipewire.service >/dev/null 2>&1; then
    say "Restarting PipeWire so the 'Noise Canceling source' appears"
    run systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
    if ((!DRY)); then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx rnnoise_source && break
        sleep 0.5
      done
      if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx rnnoise_source; then
        echo "    rnnoise_source is live"
        if ((SET_DEFAULT_SOURCE)); then run pactl set-default-source rnnoise_source; fi
      else
        warn "rnnoise_source did not appear; check: journalctl --user -u pipewire -n 30"
      fi
    fi
  else
    warn "PipeWire user service not active in this shell (running over SSH?). The filter loads on next login."
  fi
fi

# ---------------------------------------------------------------------------
# 6. Hyprland
# ---------------------------------------------------------------------------
hypr_version() {
  local v=""
  if have hyprctl; then
    v="$(hyprctl version -j 2>/dev/null | jq -r '.tag // .version // empty' 2>/dev/null || true)"
    [[ -z "$v" ]] && v="$(hyprctl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  printf '%s' "${v#v}"
}

# New "match:" window-rule syntax arrived in Hyprland 0.53. Decide which dialect to write.
uses_new_rule_syntax() {
  local v; v="$(hypr_version)"
  if [[ -n "$v" ]]; then
    local major minor; IFS=. read -r major minor _ <<<"$v"
    if (( major > 0 || minor >= 53 )); then return 0; else return 1; fi
  fi
  # No hyprctl (e.g. SSH): infer from Omarchy's own defaults.
  local d
  for d in "$HOME/.local/share/omarchy/default/hypr/windows.conf" /usr/share/omarchy/default/hypr/windows.conf; do
    [[ -r "$d" ]] && grep -q 'match:' "$d" && return 0
  done
  return 1   # conservative: legacy syntax
}

if ((DO_HYPR)); then
  if [[ -f "$HYPR_DIR/hyprland.lua" ]]; then
    say "Hyprland (Omarchy 4, Lua) -> $HYPR_DIR/live-translate.lua"
    if ((!DRY)); then sed "s|@@SCRIPT@@|$SCRIPT|g" "$HERE/config/hypr/live-translate.lua" >"$HYPR_DIR/live-translate.lua"; fi
    ensure_line "$HYPR_DIR/hyprland.lua" 'require("hypr.live-translate")'
  elif [[ -f "$HYPR_DIR/hyprland.conf" ]]; then
    if uses_new_rule_syntax; then
      tpl="$HERE/config/hypr/live-translate.conf"; dialect="windowrule/match: (Hyprland >= 0.53)"
    else
      tpl="$HERE/config/hypr/live-translate-legacy.conf"; dialect="windowrulev2 (Hyprland < 0.53)"
    fi
    say "Hyprland ($dialect) -> $HYPR_DIR/live-translate.conf"
    if ((!DRY)); then sed "s|@@SCRIPT@@|$SCRIPT|g" "$tpl" >"$HYPR_DIR/live-translate.conf"; fi
    ensure_line "$HYPR_DIR/hyprland.conf" 'source = ~/.config/hypr/live-translate.conf'
  else
    warn "no $HYPR_DIR/hyprland.conf or hyprland.lua found; skipping Hyprland config"
  fi
  if grep -rqsE 'SUPER( \+)? ?SHIFT, ?T\b|SUPER \+ SHIFT \+ T' "$HYPR_DIR"/bindings.conf "$HYPR_DIR"/bindings.lua 2>/dev/null; then
    warn "SUPER SHIFT T is also bound in your personal bindings file; both binds will fire."
  fi
  if have hyprctl && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    say "Reloading Hyprland"
    run hyprctl reload >/dev/null || warn "hyprctl reload failed"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
say "Doctor"
if ((!DRY)); then "$SCRIPT" doctor || warn "doctor reported problems (see above)"; fi
say "Done. Press SUPER+SHIFT+T (or run: $SCRIPT toggle)."
echo "    Transcripts: ${XDG_DATA_HOME:-$HOME/.local/share}/live-translate/"
echo "    Tuning:      ${XDG_CONFIG_HOME:-$HOME/.config}/live-translate/config  (e.g. LT_MODEL_SIZE=base)"
