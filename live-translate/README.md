# Live Translate

Continuous, real-time Vietnamese → English translation for long meetings (2–3+ hours) on
Arch Linux / Omarchy (Hyprland + PipeWire). No fixed-length clips, no push-to-talk:

```
microphone ─► PipeWire RNNoise filter ─► sox (silence-detection segmenter, /tmp RAM buffer)
           ─► whisper.cpp --language vi --translate ─► "Live Translate" floating terminal + transcript file
```

* **sox** listens to the mic forever and cuts a new WAV every time the speaker pauses
  (default 0.8 s below 1 % level) or after 20 s of continuous speech, whichever comes first.
* A single consumer loop feeds finished segments to **whisper.cpp** one at a time (bounded CPU,
  no pile-up of decoder processes), filters known hallucinations, prints `[HH:MM:SS] text` and
  appends to `~/.local/share/live-translate/transcript-<date>.txt`.
* Segments are deleted as soon as they are decoded, so `/tmp` never grows.
* `SUPER+SHIFT+T` toggles a pinned, floating 450×350 window titled **Live Translate** in the top-right.
* Ctrl-C, closing the window, or toggling again runs the cleanup trap: sox and whisper are killed,
  the `/tmp/live-translate.*` work dir is removed, and the pid file is cleared.

## Install (Arch / Omarchy)

```bash
git clone <this repo> && cd ilantern/live-translate
./install.sh
```

`install.sh` is idempotent and does, in order:

1. Prints the PipeWire source list (`wpctl status` / `pactl list short sources`).
2. `pacman -S sox noise-suppression-for-voice jq libnotify curl cmake base-devel git`, then
   whisper.cpp from `extra/whisper.cpp`, else AUR (`yay`: `whisper.cpp`, `whisper-cpp-git`), else a
   source build into `~/.local/bin/whisper-cli` (static, `GGML_NATIVE=ON`, falling back to explicit
   `AVX2/FMA/F16C` flags).
3. Downloads `ggml-base.bin` and `ggml-small.bin` to `~/.local/share/whisper/models/`.
4. Installs `~/.local/bin/continuous_translate.sh`.
5. Installs the RNNoise filter-chain to `~/.config/pipewire/pipewire.conf.d/99-input-denoising.conf`
   and restarts PipeWire. A virtual mic **rnnoise_source** ("Noise Canceling source") appears and the
   script uses it automatically. Add `--set-default-source` to make it the default for every app.
6. Hyprland: writes a drop-in and sources it from your main config. It detects your layout:
   * Omarchy 3.x (`hyprland.conf`): `~/.config/hypr/live-translate.conf`, in the window-rule dialect
     matching your Hyprland version (`windowrule = float on, match:title ^(Live Translate)$` on ≥ 0.53,
     `windowrulev2 = float, title:^(Live Translate)$` before that).
   * Omarchy 4 (`hyprland.lua`): `~/.config/hypr/live-translate.lua` with `o.window` / `o.bind`.
   * Then `hyprctl reload`.
7. Runs `continuous_translate.sh doctor`.

Flags: `--no-packages`, `--no-hypr`, `--no-pipewire`, `--models "small"`, `--dry-run`.

## Use

| Action | Command |
|---|---|
| Toggle window / pipeline | `SUPER+SHIFT+T` or `continuous_translate.sh` |
| Start / stop / status | `continuous_translate.sh start|stop|status` |
| Run in the current terminal | `continuous_translate.sh run` |
| Check deps, model, mic | `continuous_translate.sh doctor` |

The first lines in the window show the model, language, thread count and audio source in use.

## Tuning

Set variables in `~/.config/live-translate/config` (plain shell, sourced) or in the environment.

| Variable | Default | Meaning |
|---|---|---|
| `LT_MODEL_SIZE` | auto (`small`, else `base`) | `base` is ~2–3× faster and cooler; `small` is noticeably better for Vietnamese. |
| `LT_MODEL` | – | Explicit path to a `ggml-*.bin`. |
| `LT_LANG` / `LT_TRANSLATE` | `vi` / `1` | Source language; `0` transcribes instead of translating. |
| `LT_THREADS` | physical cores | whisper threads. Keep at physical cores (4 on the i5-1135G7) to avoid thermal throttling. |
| `LT_NICE` | `10` | whisper niceness so the UI stays responsive. |
| `LT_SOURCE` | `rnnoise_source` if present, else default mic | PipeWire/Pulse source name (`pactl list short sources`). |
| `LT_SILENCE_THRESHOLD` | `1%` | sox silence level. Raise to `2-3%` if you run without RNNoise in a noisy room. |
| `LT_SILENCE_DURATION` | `0.8` | Seconds of pause that closes a segment. Lower = snappier, more fragments. |
| `LT_MAX_SEGMENT` | `20` | Hard cap in seconds for non-stop speech (whisper's window is 30 s). |
| `LT_MIN_SEGMENT` | `0.6` | Drop shorter clips (clicks, breaths) that whisper tends to hallucinate on. |
| `LT_WHISPER_PROMPT` | – | Optional Vietnamese prompt to bias vocabulary, e.g. names or domain terms. |
| `LT_WHISPER_ARGS` | – | Extra whisper-cli flags, e.g. `-bs 1 -bo 1` for greedy (faster) decoding. |
| `LT_HALLUCINATION_RE` | built-in | Case-insensitive regex of lines to drop ("thank you for watching", "[BLANK_AUDIO]", "Ghiền Mì Gõ"…). |
| `LT_DEDUPE` | `1` | Drop a line identical to the previous one (decoder loops). |
| `LT_TMP_ROOT` | `/tmp` | RAM-backed work dir root (falls back to `/dev/shm`). |
| `LT_LOG_DIR` / `LT_KEEP_TRANSCRIPT` | `~/.local/share/live-translate` / `1` | Transcript location; `0` disables. |
| `LT_TERMINAL` | auto (`xdg-terminal-exec`, `$TERMINAL`, alacritty, ghostty, kitty, foot) | Terminal used for the window. |
| `LT_INPUT_FILE` | – | Read a WAV instead of the mic (testing). |

### Southern Vietnamese, long meetings

* Prefer `small`. If the window prints `(backlog: N segments waiting …)` repeatedly, whisper is slower
  than real time: switch to `LT_MODEL_SIZE=base` or add `LT_WHISPER_ARGS="-bs 1 -bo 1"`.
* RNNoise at `VAD Threshold 50` is tuned for continuous speech. Raise it (edit
  `99-input-denoising.conf`, restart PipeWire) to reject more room echo, at the risk of clipping soft
  syllables and tones.
* A short `LT_WHISPER_PROMPT` with names/terms in Vietnamese helps recognition; keep it under a sentence.
* Thermals: whisper runs at `nice 10` on physical cores only, one segment at a time. Expect roughly
  20–40 % sustained CPU with `small` on an 11th-gen i5; `base` roughly halves it.

## Hyprland window rules (reference)

Hyprland ≥ 0.53 (Omarchy 3.x and later):

```
windowrule = float on, match:title ^(Live Translate)$
windowrule = pin on, match:title ^(Live Translate)$
windowrule = size 450 350, match:title ^(Live Translate)$
windowrule = move 100%-470 50, match:title ^(Live Translate)$
bindd = SUPER SHIFT, T, Live Translate, exec, ~/.local/bin/continuous_translate.sh toggle
```

Older Hyprland:

```
windowrulev2 = float, title:^(Live Translate)$
windowrulev2 = pin, title:^(Live Translate)$
windowrulev2 = size 450 350, title:^(Live Translate)$
windowrulev2 = move 100%-470 50, title:^(Live Translate)$
bind = SUPER SHIFT, T, exec, ~/.local/bin/continuous_translate.sh toggle
```

The window is also launched with app-id/class `live-translate`, so `match:class ^(live-translate)$`
works as an alternative selector.

## Tests

```bash
bash live-translate/tests/run.sh
```

Runs without a mic or whisper.cpp: shellcheck, sox segmentation (pause splitting and max-length cap),
the full pipeline in file-input mode with a stub decoder, hallucination and short-clip filtering,
SIGTERM cleanup, and the installer's Hyprland dialect detection. With a real build:

```bash
LT_REAL_WHISPER_BIN=~/.local/bin/whisper-cli LT_REAL_MODEL=~/.local/share/whisper/models/ggml-base.bin \
LT_REAL_SAMPLE=path/to/jfk.wav bash live-translate/tests/run.sh
```

## Layout

```
live-translate/
├── bin/continuous_translate.sh        the pipeline (toggle/start/stop/status/run/doctor)
├── install.sh                         Arch/Omarchy installer
├── config/pipewire/99-input-denoising.conf   RNNoise filter-chain
├── config/hypr/live-translate.conf    Hyprland ≥ 0.53 drop-in
├── config/hypr/live-translate-legacy.conf    windowrulev2 drop-in
├── config/hypr/live-translate.lua     Omarchy 4 (Lua) drop-in
└── tests/                             test suite + whisper stub
```
