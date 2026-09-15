#!/usr/bin/env bash
# Stand-in for whisper-cli in tests: prints the duration of the input wav, mimicking
# whisper's output shape (leading blank line, leading space, no trailing newline).
f=""
while (($#)); do case "$1" in -f) f="$2"; shift ;; esac; shift; done
printf '\n segment %.1fs' "$(soxi -D "$f")"
