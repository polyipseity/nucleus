#!/usr/bin/env bash
# Clones or updates the superpowers plugin repo for VS Code / Cursor local
# plugin install.  Target dir is managed at a fixed path under
# ~/.local/share/nucleus/plugins/superpowers/.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_csp_git="$1"
_csp_path_prepend="$2"
_csp_path_append="$3"
_csp_target_dir="$4"
_csp_expected_rev="$5"

# Add managed bin directories to PATH for the current session.
PATH="${_csp_path_prepend}$PATH${_csp_path_append}"
export PATH

_csp_repo_url="https://github.com/obra/superpowers.git"

# --- Idempotent: dir exists and HEAD already matches → skip ---
if [ -d "$_csp_target_dir" ]; then
  _csp_current_rev="$("$_csp_git" -C "$_csp_target_dir" rev-parse HEAD 2>/dev/null || true)" # check-suppress:suppression_doc: directory may not exist yet — rev-parse failure is expected
  if [ "$_csp_current_rev" = "$_csp_expected_rev" ]; then
    say -l clone-superpowers "superpowers already at expected rev $_csp_expected_rev; skipping"
    exit 0
  fi

  # Dir exists but HEAD doesn't match → update in place.
  warn -l clone-superpowers "superpowers HEAD $_csp_current_rev != expected $_csp_expected_rev; updating"
  if ! "$_csp_git" -C "$_csp_target_dir" fetch origin; then
    warn -l clone-superpowers "git fetch failed for $_csp_target_dir; skipping update"
    exit 0
  fi
  if ! "$_csp_git" -C "$_csp_target_dir" checkout "$_csp_expected_rev"; then
    warn -l clone-superpowers "git checkout $_csp_expected_rev failed; skipping update"
    exit 0
  fi
else
  # --- Dir doesn't exist → shallow clone then fetch the exact rev ---
  say -l clone-superpowers "cloning superpowers into $_csp_target_dir"
  if ! "$_csp_git" clone --depth 1 "$_csp_repo_url" "$_csp_target_dir"; then
    warn -l clone-superpowers "git clone failed; skipping"
    exit 0
  fi
  if ! "$_csp_git" -C "$_csp_target_dir" fetch --depth 1 origin "$_csp_expected_rev"; then
    warn -l clone-superpowers "git fetch --depth 1 failed; skipping checkout"
    exit 0
  fi
  if ! "$_csp_git" -C "$_csp_target_dir" checkout FETCH_HEAD; then
    warn -l clone-superpowers "git checkout FETCH_HEAD failed; skipping"
    exit 0
  fi
fi

# Verify HEAD matches after clone/update.
_csp_final_rev="$("$_csp_git" -C "$_csp_target_dir" rev-parse HEAD 2>/dev/null || true)" # check-suppress:suppression_doc: defensive fallback — warn on rev mismatch below
if [ "$_csp_final_rev" != "$_csp_expected_rev" ]; then
  warn -l clone-superpowers "HEAD is $_csp_final_rev after update; expected $_csp_expected_rev"
fi
