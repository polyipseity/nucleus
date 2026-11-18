#!/usr/bin/env bash
# Copies stdin to the system clipboard through one shared command, so prompt
# tooling in every harness stays off per-platform clipboard detection (R7).
#
#   harness-clipboard
#       Reads the text on stdin and copies it. Exits 0 on success, non-zero with
#       a named reason when no backend exists.
#
# Backend order: pbcopy (macOS), clip.exe (Windows), wl-copy then
# `xclip -selection clipboard` (Linux). NUCLEUS_CLIPBOARD_BACKEND overrides the
# selection for tests and callers that know the backend name.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 harness-clipboard
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/nucleus-clipboard.XXXXXX")"
cleanup() {
  # Keep cleanup non-interactive: safe-delete wrappers may prompt when Trash or
  # a graveyard is absent in an isolated environment.
  if [ -n "${HOME-}" ]; then
    mkdir -p "$HOME/.Trash" 2>/dev/null || true # check-suppress:suppression_doc: temp cleanup must not fail the command
  fi
  rm -f -- "$tmp_file" >/dev/null 2>&1 || true # check-suppress:suppression_doc: temp cleanup must not fail the command
}
trap cleanup EXIT

cat >"$tmp_file"

backend="${NUCLEUS_CLIPBOARD_BACKEND-}"
if [ -z "$backend" ]; then
  if command -v pbcopy >/dev/null 2>&1; then
    backend="pbcopy"
  elif command -v clip.exe >/dev/null 2>&1; then
    backend="clip.exe"
  elif command -v wl-copy >/dev/null 2>&1; then
    backend="wl-copy"
  elif command -v xclip >/dev/null 2>&1; then
    backend="xclip -selection clipboard"
  else
    die "no clipboard backend available (tried pbcopy, clip.exe, wl-copy, xclip)"
  fi
fi

case "$backend" in
pbcopy)
  command -v pbcopy >/dev/null 2>&1 || die "clipboard backend unavailable: pbcopy"
  pbcopy <"$tmp_file"
  ;;
clip.exe)
  command -v clip.exe >/dev/null 2>&1 || die "clipboard backend unavailable: clip.exe"
  clip.exe <"$tmp_file"
  ;;
wl-copy)
  command -v wl-copy >/dev/null 2>&1 || die "clipboard backend unavailable: wl-copy"
  wl-copy <"$tmp_file"
  ;;
"xclip -selection clipboard")
  command -v xclip >/dev/null 2>&1 || die "clipboard backend unavailable: xclip"
  xclip -selection clipboard <"$tmp_file"
  ;;
*)
  die "clipboard backend unavailable: $backend"
  ;;
esac
