#!/usr/bin/env bash
# continuous_translate.sh - continuous, VAD-segmented live translation (Vietnamese -> English)
#
# Architecture
#   sox (pulse/pipewire mic) --silence-split--> /tmp segments --> whisper.cpp --translate --> stdout + transcript
#
# Usage
#   continuous_translate.sh            # toggle: open a "Live Translate" terminal, or stop the running one
#   continuous_translate.sh toggle     # same as above
#   continuous_translate.sh start      # open the window if not running
#   continuous_translate.sh stop       # stop a running pipeline
#   continuous_translate.sh status     # print running / stopped
#   continuous_translate.sh run        # run the pipeline in the current terminal (what the window executes)
#   continuous_translate.sh doctor     # check dependencies, model, audio source
#
# Configuration: environment variables, or ~/.config/live-translate/config (sourced as shell).
# See README.md for the full list. Everything is prefixed LT_.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LT_CONFIG_FILE="${LT_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/live-translate/config}"
if [[ -r "$LT_CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$LT_CONFIG_FILE"
fi

LT_TITLE="${LT_TITLE:-Live Translate}"
LT_APP_ID="${LT_APP_ID:-live-translate}"
LT_LANG="${LT_LANG:-vi}"
LT_TRANSLATE="${LT_TRANSLATE:-1}"                 # 1 = translate to English, 0 = transcribe only
LT_MODEL_SIZE="${LT_MODEL_SIZE:-}"                # base | small | ... (auto: small, then base)
LT_MODEL="${LT_MODEL:-}"                          # explicit path to a ggml-*.bin (overrides LT_MODEL_SIZE)
LT_MODEL_DIRS="${LT_MODEL_DIRS:-${XDG_DATA_HOME:-$HOME/.local/share}/whisper/models:/usr/share/whisper.cpp/models:/usr/share/whisper.cpp-models:/usr/share/whisper}"
LT_WHISPER_BIN="${LT_WHISPER_BIN:-}"              # auto-detected: whisper-cli, whisper-cpp, ...
LT_WHISPER_ARGS="${LT_WHISPER_ARGS:-}"            # extra args appended to whisper
LT_WHISPER_PROMPT="${LT_WHISPER_PROMPT:-}"        # optional initial prompt (source language), biases vocabulary
LT_WHISPER_TIMEOUT="${LT_WHISPER_TIMEOUT:-90}"    # seconds; a hung decode never blocks the queue forever
LT_THREADS="${LT_THREADS:-}"                      # default: number of physical cores
LT_NICE="${LT_NICE:-10}"                          # niceness for whisper (thermal / UI friendliness)
LT_SOURCE="${LT_SOURCE:-}"                        # pulse source name; auto: rnnoise_source, else default
LT_SILENCE_THRESHOLD="${LT_SILENCE_THRESHOLD:-1%}" # sox silence level (raise to 2-3% without RNNoise)
LT_SILENCE_DURATION="${LT_SILENCE_DURATION:-0.8}"  # seconds of silence that ends a segment
LT_MAX_SEGMENT="${LT_MAX_SEGMENT:-20}"             # hard cap (s) so continuous speech still yields output
LT_MIN_SEGMENT="${LT_MIN_SEGMENT:-0.6}"            # drop segments shorter than this (clicks, breaths)
LT_TMP_ROOT="${LT_TMP_ROOT:-/tmp}"                # RAM-backed on Arch (tmpfs); /dev/shm also fine
LT_LOG_DIR="${LT_LOG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/live-translate}"
LT_KEEP_TRANSCRIPT="${LT_KEEP_TRANSCRIPT:-1}"     # 1 = append every line to a dated transcript file
LT_POLL_INTERVAL="${LT_POLL_INTERVAL:-0.15}"      # seconds between queue scans
LT_BACKLOG_WARN="${LT_BACKLOG_WARN:-4}"           # warn when this many segments are waiting
LT_INPUT_FILE="${LT_INPUT_FILE:-}"                # testing: read this wav instead of the microphone
LT_TERMINAL="${LT_TERMINAL:-}"                    # force a terminal: xdg-terminal-exec|alacritty|ghostty|kitty|foot
LT_NOTIFY="${LT_NOTIFY:-1}"                       # desktop notification on start/stop when notify-send exists
LT_DEDUPE="${LT_DEDUPE:-1}"                       # 1 = drop a line identical to the previous one (decoder loops)
# Case-insensitive extended regex of known Whisper hallucinations on silence/noise.
LT_HALLUCINATION_RE="${LT_HALLUCINATION_RE:-^[[:space:][:punct:]]*$|^\[?(blank_audio|music|applause|laughter|silence|inaudible)\]?$|^\(.*\)$|thank(s| you) for watching|subscribe|like and share|see you (in|on) the next|ghi[eề]n m[iì] g[oõ]|hẹn gặp lại|cảm ơn (các bạn )?đã (theo dõi|xem)}"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="${LT_PID_FILE:-$RUNTIME_DIR/live-translate.pid}"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
die()  { log "error: $*"; exit 1; }
ts()   { date +%H:%M:%S; }
have() { command -v "$1" >/dev/null 2>&1; }

notify() {
  [[ "$LT_NOTIFY" == 1 ]] || return 0
  have notify-send || return 0
  notify-send -a "$LT_TITLE" -u low "$LT_TITLE" "$*" >/dev/null 2>&1 || true
}

physical_cores() {
  local n=""
  if have lscpu; then
    n="$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
  fi
  if [[ -z "$n" || "$n" -lt 1 ]]; then
    n=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
  fi
  (( n < 1 )) && n=1
  printf '%s' "$n"
}

find_whisper_bin() {
  local c
  if [[ -n "$LT_WHISPER_BIN" ]]; then
    [[ -x "$LT_WHISPER_BIN" ]] && { printf '%s' "$LT_WHISPER_BIN"; return 0; }
    have "$LT_WHISPER_BIN" && { command -v "$LT_WHISPER_BIN"; return 0; }
    return 1
  fi
  for c in whisper-cli whisper-cpp whisper.cpp whisper-cpp-cli "$HOME/.local/bin/whisper-cli"; do
    if [[ -x "$c" ]]; then printf '%s' "$c"; return 0; fi
    if have "$c"; then command -v "$c"; return 0; fi
  done
  return 1
}

find_model() {
  local dir size
  if [[ -n "$LT_MODEL" ]]; then
    [[ -r "$LT_MODEL" ]] && { printf '%s' "$LT_MODEL"; return 0; }
    return 1
  fi
  local sizes=("small" "base")
  [[ -n "$LT_MODEL_SIZE" ]] && sizes=("$LT_MODEL_SIZE")
  for size in "${sizes[@]}"; do
    IFS=: read -r -a dirs <<<"$LT_MODEL_DIRS"
    for dir in "${dirs[@]}"; do
      [[ -r "$dir/ggml-$size.bin" ]] && { printf '%s' "$dir/ggml-$size.bin"; return 0; }
    done
  done
  return 1
}

# Pick the PulseAudio/PipeWire source: explicit > rnnoise_source (if present) > default.
find_source() {
  if [[ -n "$LT_SOURCE" ]]; then printf '%s' "$LT_SOURCE"; return 0; fi
  if have pactl && pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx 'rnnoise_source'; then
    printf '%s' "rnnoise_source"; return 0
  fi
  printf '%s' "@DEFAULT_SOURCE@"
}

is_running() {
  local pid
  [[ -r "$PID_FILE" ]] || return 1
  pid="$(<"$PID_FILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Terminal launcher (toggle/start)
# ---------------------------------------------------------------------------
launch_window() {
  local term="$LT_TERMINAL" cmd=()
  if [[ -z "$term" ]]; then
    if have xdg-terminal-exec; then term=xdg-terminal-exec
    elif [[ -n "${TERMINAL:-}" ]] && have "$TERMINAL"; then term="$TERMINAL"
    else
      local t
      for t in alacritty ghostty kitty foot wezterm; do have "$t" && { term="$t"; break; }; done
    fi
  fi
  [[ -n "$term" ]] || die "no terminal emulator found (set LT_TERMINAL)"

  case "$(basename "$term")" in
    xdg-terminal-exec) cmd=("$term" "--title=$LT_TITLE" "--app-id=$LT_APP_ID" -e "$SELF" run) ;;
    alacritty) cmd=("$term" -T "$LT_TITLE" --class "$LT_APP_ID" -o window.dynamic_title=false -e "$SELF" run) ;;
    ghostty)   cmd=("$term" "--title=$LT_TITLE" "--class=$LT_APP_ID" -e "$SELF" run) ;;
    kitty)     cmd=("$term" --title "$LT_TITLE" --class "$LT_APP_ID" "$SELF" run) ;;
    foot)      cmd=("$term" -T "$LT_TITLE" -a "$LT_APP_ID" "$SELF" run) ;;
    wezterm)   cmd=("$term" start --class "$LT_APP_ID" -- "$SELF" run) ;;
    *)         cmd=("$term" -e "$SELF" run) ;;
  esac

  # Detach fully so a Hyprland `exec` bind (or a shell) never keeps us as a child.
  if have uwsm-app && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    setsid -f uwsm-app -- "${cmd[@]}" >/dev/null 2>&1 </dev/null
  else
    setsid -f "${cmd[@]}" >/dev/null 2>&1 </dev/null
  fi
}

cmd_start() {
  if is_running; then log "already running (pid $(<"$PID_FILE"))"; return 0; fi
  launch_window
}

cmd_stop() {
  if ! is_running; then log "not running"; rm -f "$PID_FILE"; return 0; fi
  local pid; pid="$(<"$PID_FILE")"
  kill -TERM "$pid" 2>/dev/null || true
  # wait up to 10s for a clean exit, then escalate
  local i
  for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  log "stopped"
}

cmd_toggle() { if is_running; then cmd_stop; else cmd_start; fi; }

cmd_status() {
  if is_running; then echo "running (pid $(<"$PID_FILE"))"; else echo "stopped"; return 1; fi
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------
cmd_doctor() {
  local ok=0 bin model src
  echo "== live-translate doctor"
  for t in sox soxi timeout setsid; do
    if have "$t"; then echo "  [ok]   $t: $(command -v "$t")"; else echo "  [MISS] $t"; ok=1; fi
  done
  if sox --help 2>&1 | grep -qi pulseaudio; then echo "  [ok]   sox has pulseaudio support"; else echo "  [WARN] sox built without pulseaudio support"; fi
  if bin="$(find_whisper_bin)"; then echo "  [ok]   whisper: $bin"; else echo "  [MISS] whisper.cpp binary (whisper-cli); set LT_WHISPER_BIN"; ok=1; fi
  if model="$(find_model)"; then echo "  [ok]   model:   $model"; else echo "  [MISS] model ggml-{small,base}.bin in $LT_MODEL_DIRS"; ok=1; fi
  echo "  [info] threads: ${LT_THREADS:-$(physical_cores)} (physical cores), nice $LT_NICE"
  if have pactl; then
    src="$(find_source)"
    echo "  [info] source:  $src"
    if [[ "$src" == "@DEFAULT_SOURCE@" ]]; then
      echo "  [info] default: $(pactl get-default-source 2>/dev/null || echo '?')"
      echo "  [WARN] rnnoise_source not found: RNNoise filter not loaded (see config/pipewire)"
    fi
    echo "  -- sources (pactl list short sources):"
    pactl list short sources 2>/dev/null | sed 's/^/     /'
  else
    echo "  [WARN] pactl not available: cannot inspect PipeWire sources"
  fi
  if have wpctl; then
    echo "  -- wpctl status (Sources):"
    wpctl status 2>/dev/null | sed -n '/Sources:/,/^ *$/p' | sed 's/^/     /'
  fi
  if have hyprctl; then
    echo "  [info] hyprland: $(hyprctl version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if hyprctl binds 2>/dev/null | grep -q "continuous_translate"; then echo "  [ok]   keybind present"; else echo "  [WARN] keybind for continuous_translate.sh not found in hyprctl binds"; fi
  fi
  echo "  [info] tmp root: $LT_TMP_ROOT ($(df -hT "$LT_TMP_ROOT" 2>/dev/null | awk 'NR==2{print $2", "$5" free"}'))"
  echo "  [info] transcripts: $LT_LOG_DIR"
  return $ok
}

# ---------------------------------------------------------------------------
# Pipeline (run)
# ---------------------------------------------------------------------------
WORK=""; REC_LOOP_PID=""; LOGFILE=""; TRANSCRIPT=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  printf '\n[%s] stopping...\n' "$(ts)"
  if [[ -n "$REC_LOOP_PID" ]]; then
    kill -TERM "$REC_LOOP_PID" 2>/dev/null || true
  fi
  if [[ -n "$WORK" && -r "$WORK/sox.pid" ]]; then
    kill -TERM "$(<"$WORK/sox.pid")" 2>/dev/null || true
  fi
  if [[ -n "$WORK" && -r "$WORK/whisper.pid" ]]; then
    kill -TERM -- "-$(<"$WORK/whisper.pid")" 2>/dev/null || kill -TERM "$(<"$WORK/whisper.pid")" 2>/dev/null || true
  fi
  # give children a moment, then make sure nothing survives
  sleep 0.3
  [[ -n "$REC_LOOP_PID" ]] && kill -KILL "$REC_LOOP_PID" 2>/dev/null
  [[ -n "$WORK" && -r "$WORK/sox.pid" ]] && kill -KILL "$(<"$WORK/sox.pid")" 2>/dev/null
  [[ -n "$WORK" && -r "$WORK/whisper.pid" ]] && kill -KILL -- "-$(<"$WORK/whisper.pid")" 2>/dev/null
  wait 2>/dev/null
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
  [[ -r "$PID_FILE" && "$(<"$PID_FILE")" == "$$" ]] && rm -f "$PID_FILE"
  [[ -n "$TRANSCRIPT" ]] && printf '[%s] transcript saved: %s\n' "$(ts)" "$TRANSCRIPT"
  notify "Stopped"
  exit "$rc"
}

# Background recorder: one sox process per "run"; restarts on device loss (live mode).
recorder_loop() {
  local run=0 prefix src=()
  while [[ -e "$WORK/running" ]]; do
    run=$((run + 1))
    prefix=$(printf '%s/seg-%04d-' "$WORK" "$run")
    if [[ -n "$LT_INPUT_FILE" ]]; then
      src=("$LT_INPUT_FILE")
    else
      src=(-r 16000 -c 1 -b 16 -t pulseaudio "$SOURCE")
    fi
    # Effect chain: strip leading silence, stop at LT_SILENCE_DURATION of silence,
    # or after LT_MAX_SEGMENT seconds of speech; then open a new file and restart.
    sox -q "${src[@]}" -r 16000 -c 1 -b 16 -e signed-integer "${prefix}.wav" \
      silence 1 0.1 "$LT_SILENCE_THRESHOLD" 1 "$LT_SILENCE_DURATION" "$LT_SILENCE_THRESHOLD" \
      trim 0 "$LT_MAX_SEGMENT" : newfile : restart \
      2>>"$LOGFILE" &
    echo $! >"$WORK/sox.pid"
    wait $! 2>/dev/null
    rm -f "$WORK/sox.pid"
    if [[ -n "$LT_INPUT_FILE" ]]; then break; fi   # file mode: single pass
    [[ -e "$WORK/running" ]] || break
    printf '[%s] audio input ended (device change?) - reconnecting\n' "$(ts)"
    sleep 1
  done
  : >"$WORK/recorder_done"
}

# Run whisper on one segment; print filtered text lines.
transcribe() {
  local wav="$1" dur="$2"
  local in="$wav"
  local args=(-m "$MODEL" -l "$LT_LANG" -t "$THREADS" -nt -np -nf -sns)
  [[ "$LT_TRANSLATE" == 1 ]] && args+=(-tr)
  [[ -n "$LT_WHISPER_PROMPT" ]] && args+=(--prompt "$LT_WHISPER_PROMPT")
  # shellcheck disable=SC2206
  [[ -n "$LT_WHISPER_ARGS" ]] && args+=($LT_WHISPER_ARGS)

  # Whisper wants >= 1 s of audio; pad very short clips with silence.
  if awk -v d="$dur" 'BEGIN{exit !(d < 1.1)}'; then
    in="$WORK/pad/$(basename "$wav")"
    sox -q "$wav" "$in" pad 0 1.0 2>>"$LOGFILE" || in="$wav"
  fi

  # Run whisper in the background in its own process group and wait() for it:
  # `wait` is interruptible, so a SIGTERM (toggle/stop) is handled immediately
  # and cleanup can kill the whole group instead of waiting for the decode.
  local outfile="$WORK/whisper.out" rc
  : >"$outfile"
  setsid nice -n "$LT_NICE" timeout -k 5 "$LT_WHISPER_TIMEOUT" "$WHISPER" "${args[@]}" -f "$in" \
    >"$outfile" 2>>"$LOGFILE" </dev/null &
  echo $! >"$WORK/whisper.pid"
  wait $!
  rc=$?
  rm -f "$WORK/whisper.pid" "$WORK/pad/$(basename "$wav")"
  if (( rc == 124 )); then printf '[%s] (whisper timed out on a %.1fs segment, skipped)\n' "$(ts)" "$dur"; return 0; fi
  if (( rc != 0 )); then printf '[%s] (whisper exited %d, see %s)\n' "$(ts)" "$rc" "$LOGFILE"; return 0; fi

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue
    if grep -qiE -- "$LT_HALLUCINATION_RE" <<<"$line"; then continue; fi
    [[ "$LT_DEDUPE" == 1 && "$line" == "$LAST_LINE" ]] && continue   # decoder loop / repeated hallucination
    LAST_LINE="$line"
    printf '[%s] %s\n' "$(ts)" "$line"
    if [[ -n "$TRANSCRIPT" ]]; then printf '[%s] %s\n' "$(date +%F\ %T)" "$line" >>"$TRANSCRIPT"; fi
  done <"$outfile"
}

cmd_run() {
  have sox || die "sox is not installed"
  have soxi || die "soxi (part of sox) is not installed"
  WHISPER="$(find_whisper_bin)" || die "whisper.cpp binary not found (whisper-cli); set LT_WHISPER_BIN"
  MODEL="$(find_model)" || die "no model found; run install.sh or set LT_MODEL"
  THREADS="${LT_THREADS:-$(physical_cores)}"
  SOURCE="$(find_source)"
  LAST_LINE=""

  if is_running && [[ "$(<"$PID_FILE")" != "$$" ]]; then
    die "already running (pid $(<"$PID_FILE")); use 'stop' first"
  fi
  mkdir -p "$(dirname "$PID_FILE")"
  echo $$ >"$PID_FILE"

  [[ -d "$LT_TMP_ROOT" && -w "$LT_TMP_ROOT" ]] || LT_TMP_ROOT=/dev/shm
  WORK="$(mktemp -d "$LT_TMP_ROOT/live-translate.XXXXXX")" || die "cannot create work dir"
  LOGFILE="$WORK/pipeline.log"
  : >"$LOGFILE"
  if [[ "$LT_KEEP_TRANSCRIPT" == 1 ]]; then
    mkdir -p "$LT_LOG_DIR"
    TRANSCRIPT="$LT_LOG_DIR/transcript-$(date +%Y%m%d-%H%M%S).txt"
  fi

  trap cleanup EXIT INT TERM HUP

  # Set the window title from inside too (belt and braces for terminals that ignore --title).
  [[ -t 1 ]] && printf '\033]0;%s\a' "$LT_TITLE"

  printf '[%s] %s\n' "$(ts)" "$LT_TITLE"
  printf '[%s] model %s | %s -> %s | threads %s | source %s\n' "$(ts)" "$(basename "$MODEL")" "$LT_LANG" \
    "$([[ "$LT_TRANSLATE" == 1 ]] && echo en || echo "$LT_LANG")" "$THREADS" "${LT_INPUT_FILE:-$SOURCE}"
  printf '[%s] split on %ss silence @%s, max %ss | Ctrl-C or SUPER+SHIFT+T to stop\n' "$(ts)" \
    "$LT_SILENCE_DURATION" "$LT_SILENCE_THRESHOLD" "$LT_MAX_SEGMENT"
  notify "Listening on ${LT_INPUT_FILE:-$SOURCE}"

  : >"$WORK/running"
  mkdir -p "$WORK/pad"
  recorder_loop &
  REC_LOOP_PID=$!

  # Processor loop: single consumer, one whisper at a time (bounded CPU, no thread pile-up).
  local -a files
  local f n i dur backlog_warned=0
  while :; do
    files=("$WORK"/seg-*.wav)
    if [[ ${#files[@]} -eq 1 && ! -e "${files[0]}" ]]; then files=(); fi   # glob did not match
    if (( ${#files[@]} > 1 )); then mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -V); fi
    n=${#files[@]}
    # The newest file is still being written unless the recorder has finished.
    if [[ -e "$WORK/recorder_done" ]]; then
      (( n == 0 )) && break
    else
      (( n <= 1 )) && { sleep "$LT_POLL_INTERVAL"; continue; }
      n=$((n - 1))
    fi
    if (( n >= LT_BACKLOG_WARN )) && (( backlog_warned == 0 )); then
      if [[ "$(basename "$MODEL")" == "ggml-base.bin" || "$(basename "$MODEL")" == "ggml-tiny.bin" ]]; then
        printf '[%s] (backlog: %d segments waiting - whisper is slower than real time)\n' "$(ts)" "$n"
      else
        printf '[%s] (backlog: %d segments waiting - consider LT_MODEL_SIZE=base)\n' "$(ts)" "$n"
      fi
      backlog_warned=1
    elif (( n < 2 )); then
      backlog_warned=0
    fi
    for (( i = 0; i < n; i++ )); do
      f="${files[$i]}"
      dur="$(soxi -D "$f" 2>/dev/null || echo 0)"
      if awk -v d="$dur" -v m="$LT_MIN_SEGMENT" 'BEGIN{exit !(d >= m)}'; then
        transcribe "$f" "$dur"
      fi
      rm -f -- "$f"
    done
  done

  printf '[%s] input finished\n' "$(ts)"
}

# ---------------------------------------------------------------------------
usage() { sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'; }

case "${1:-toggle}" in
  toggle) cmd_toggle ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  run)    cmd_run ;;
  doctor) cmd_doctor ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
