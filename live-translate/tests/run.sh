#!/usr/bin/env bash
# Test suite for live-translate. Needs: bash, sox, shellcheck (optional), timeout.
# shellcheck disable=SC2015,SC2016,SC2001
# Runs without a microphone or PipeWire (file-input mode) and without whisper.cpp (stub).
# Set LT_WHISPER_BIN and LT_MODEL to also run the real-model test.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
SCRIPT="$ROOT/bin/continuous_translate.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

echo "== 1. static checks"
bash -n "$SCRIPT" && bash -n "$ROOT/install.sh" && pass "bash -n" || fail "bash -n"
if command -v shellcheck >/dev/null; then
  shellcheck -S style "$SCRIPT" "$ROOT/install.sh" "$HERE/run.sh" "$HERE/fake-whisper.sh" && pass shellcheck || fail shellcheck
else
  echo "  skip shellcheck (not installed)"
fi

echo "== 2. sox silence segmentation"
# "speech" = 3 s tone bursts; pauses = 2 s silence. Expect 3 non-empty segments.
sox -n -r 16000 -c 1 -b 16 "$T/tone.wav" synth 3 sine 300 sine 700 vol 0.4
sox -n -r 16000 -c 1 -b 16 "$T/sil.wav" trim 0 2
sox "$T/tone.wav" "$T/sil.wav" "$T/tone.wav" "$T/sil.wav" "$T/tone.wav" "$T/sil.wav" "$T/speech3.wav"
mkdir -p "$T/seg"
sox -q "$T/speech3.wav" -r 16000 -c 1 -b 16 "$T/seg/s.wav" silence 1 0.1 1% 1 0.8 1% trim 0 20 : newfile : restart 2>/dev/null
n=0; for f in "$T"/seg/s*.wav; do d="$(soxi -D "$f")"; awk -v d="$d" 'BEGIN{exit !(d>=2.5 && d<=3.5)}' && n=$((n+1)); done
check "3 segments of ~3 s (got $n)" [ "$n" -eq 3 ]
# Long continuous speech must be capped by trim.
sox -n -r 16000 -c 1 -b 16 "$T/long.wav" synth 12 sine 300 vol 0.4
mkdir -p "$T/seg2"
sox -q "$T/long.wav" -r 16000 -c 1 -b 16 "$T/seg2/s.wav" silence 1 0.1 1% 1 0.8 1% trim 0 5 : newfile : restart 2>/dev/null
maxd=0; for f in "$T"/seg2/s*.wav; do d="$(soxi -D "$f")"; awk -v d="$d" -v m="$maxd" 'BEGIN{exit !(d>m)}' && maxd="$d"; done
check "max-segment cap respected (longest ${maxd}s <= 5.1)" awk -v d="$maxd" 'BEGIN{exit !(d<=5.1)}'

echo "== 3. pipeline, file input, stub whisper"
export LT_NOTIFY=0 LT_KEEP_TRANSCRIPT=1 LT_DEDUPE=0 LT_TMP_ROOT="$T/tmp" LT_LOG_DIR="$T/logs" LT_PID_FILE="$T/lt.pid"
mkdir -p "$LT_TMP_ROOT"
out="$(LT_WHISPER_BIN="$HERE/fake-whisper.sh" LT_MODEL="$HERE/fake-whisper.sh" LT_INPUT_FILE="$T/speech3.wav" timeout 60 "$SCRIPT" run 2>&1)"
rc=$?
check "run exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
lines="$(grep -c 'segment 3\.[0-9]s' <<<"$out")"
check "3 translated lines emitted (got $lines)" [ "$lines" -eq 3 ]
check "transcript written" bash -c 'ls "$LT_LOG_DIR"/transcript-*.txt >/dev/null 2>&1 && [ "$(cat "$LT_LOG_DIR"/transcript-*.txt | grep -c segment)" -eq 3 ]'
check "work dir removed" bash -c '! ls -d "$LT_TMP_ROOT"/live-translate.* >/dev/null 2>&1'
check "pid file removed" [ ! -e "$LT_PID_FILE" ]
check "no leftover sox" bash -c '! pgrep -f "^sox .*live-translate" >/dev/null'

echo "== 4. hallucination + short-segment filters"
cat >"$T/halluc.sh" <<'EOS'
#!/usr/bin/env bash
f=""; while (($#)); do case "$1" in -f) f="$2"; shift;; esac; shift; done
d="$(soxi -D "$f")"
if awk -v d="$d" 'BEGIN{exit !(d<2)}'; then printf ' Thank you for watching!\n [BLANK_AUDIO]\n'; else printf ' real text %.0f\n Hãy subscribe cho kênh Ghiền Mì Gõ\n' "$d"; fi
EOS
chmod +x "$T/halluc.sh"
sox -n -r 16000 -c 1 -b 16 "$T/click.wav" synth 0.3 sine 500 vol 0.4     # < LT_MIN_SEGMENT: dropped
sox -n -r 16000 -c 1 -b 16 "$T/short.wav" synth 1.2 sine 500 vol 0.4     # short: hallucination lines only
sox "$T/click.wav" "$T/sil.wav" "$T/short.wav" "$T/sil.wav" "$T/tone.wav" "$T/sil.wav" "$T/mix.wav"
out="$(LT_WHISPER_BIN="$T/halluc.sh" LT_MODEL="$T/halluc.sh" LT_INPUT_FILE="$T/mix.wav" timeout 60 "$SCRIPT" run 2>&1)"
check "real line kept" grep -q 'real text 3' <<<"$out"
check "hallucinations filtered" bash -c '! grep -qiE "thank you|BLANK|subscribe" <<<"$1"' _ "$out"

echo "== 5. stop mid-run cleans up (SIGTERM path)"
cat >"$T/slow.sh" <<'EOS'
#!/usr/bin/env bash
sleep 30; printf ' late'
EOS
chmod +x "$T/slow.sh"
LT_WHISPER_BIN="$T/slow.sh" LT_MODEL="$T/slow.sh" LT_INPUT_FILE="$T/speech3.wav" "$SCRIPT" run >"$T/stop.out" 2>&1 &
bg=$!
for _ in $(seq 1 50); do [ -e "$LT_PID_FILE" ] && pgrep -P "$bg" >/dev/null && break; sleep 0.1; done
sleep 0.5
check "status reports running" "$SCRIPT" status
"$SCRIPT" stop >/dev/null 2>&1
wait "$bg" 2>/dev/null
check "no leftover whisper stub" bash -c '! pgrep -f "^(/usr/bin/)?(bash )?'"$T"'/slow.sh" >/dev/null'
check "work dir removed after stop" bash -c '! ls -d "$LT_TMP_ROOT"/live-translate.* >/dev/null 2>&1'
check "pid file removed after stop" [ ! -e "$LT_PID_FILE" ]
check "stop message printed" grep -q 'stopping' "$T/stop.out"

echo "== 6. install.sh dry run (Hyprland dialect selection)"
fakehome="$T/home"; mkdir -p "$fakehome/.config/hypr"
printf '# test\n' >"$fakehome/.config/hypr/hyprland.conf"
out="$(HOME="$fakehome" bash "$ROOT/install.sh" --dry-run --no-packages --no-pipewire 2>&1 || true)"
if command -v hyprctl >/dev/null; then echo "  skip legacy-dialect check (hyprctl present)"; else
check "legacy dialect without hyprctl/omarchy" grep -q 'windowrulev2' <<<"$out"; fi
mkdir -p "$fakehome/.local/share/omarchy/default/hypr"; echo 'windowrule = float on, match:class x' >"$fakehome/.local/share/omarchy/default/hypr/windows.conf"
out="$(HOME="$fakehome" bash "$ROOT/install.sh" --dry-run --no-packages --no-pipewire 2>&1 || true)"
check "new dialect inferred from Omarchy defaults" grep -q 'Hyprland >= 0.53' <<<"$out"
rm -f "$fakehome/.config/hypr/hyprland.conf"; printf -- '-- lua\n' >"$fakehome/.config/hypr/hyprland.lua"
out="$(HOME="$fakehome" bash "$ROOT/install.sh" --dry-run --no-packages --no-pipewire 2>&1 || true)"
check "Omarchy 4 Lua layout detected" grep -q 'live-translate.lua' <<<"$out"

if [[ -n "${LT_REAL_WHISPER_BIN:-}" && -n "${LT_REAL_MODEL:-}" && -r "${LT_REAL_SAMPLE:-}" ]]; then
  echo "== 7. real whisper.cpp end-to-end (LT_REAL_*)"
  sox "$LT_REAL_SAMPLE" -r 16000 -c 1 -b 16 "$T/sample16.wav"
  sox "$T/sample16.wav" "$T/sil.wav" "$T/sample16.wav" "$T/sil.wav" "$T/real.wav"
  out="$(LT_WHISPER_BIN="$LT_REAL_WHISPER_BIN" LT_MODEL="$LT_REAL_MODEL" LT_LANG="${LT_REAL_LANG:-en}" LT_INPUT_FILE="$T/real.wav" timeout 300 "$SCRIPT" run 2>&1)"
  echo "$out" | sed 's/^/    /'
  check "two translated lines" [ "$(grep -c "${LT_REAL_EXPECT:-fellow Americans}" <<<"$out")" -eq 2 ]
fi

echo
if ((fail)); then echo "SOME TESTS FAILED"; exit 1; else echo "ALL TESTS PASSED"; fi
