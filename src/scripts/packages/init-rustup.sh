#!/usr/bin/env bash
# Rustup initialisation for POSIX hosts.
# Consumes rustup store path at activation time.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_rustup_bin="$1"
_rustup_jq="${2:-jq}"

# Read version pins from the consolidated lockfile so the toolchain is
# reproducible (closes the drift root cause).  Falls back to the bare
# channel if the lockfile is unavailable (best-effort, mirrors Windows
# Invoke-RustupSetup.ps1).
_rustup_lockfile=""
# check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to bare stable.
_rustup_repo_root="$(derive_repo_root 2>/dev/null || true)"
if [ -n "$_rustup_repo_root" ] && [ -f "$_rustup_repo_root/src/lockfiles/lockfile.json" ]; then
  _rustup_lockfile="$_rustup_repo_root/src/lockfiles/lockfile.json"
fi

# Add rustup's directory to PATH so the tool is available for
# subsequent operations that expect it on PATH.
_rustup_bin_dir="$(dirname "$_rustup_bin")"
PATH="$_rustup_bin_dir:$PATH"
export PATH

if [ ! -x "$_rustup_bin" ]; then
  warn -l rustup "$_rustup_bin not found in nix store; skipping initialization"
else
  # WHY: none: forces every project to declare its toolchain via
  # rust-toolchain.toml; prevents silent use of a global stable and
  # matches Windows Invoke-RustupSetup.
  "$_rustup_bin" default none
  say -l rustup "default toolchain set to none"

  # Install the stable toolchain so cargo +stable is available for
  # cargo-binstall compilation (fallback) and cargo install --list operations.
  # Mirrors Windows Invoke-RustupSetup desiredChannels=["stable"] behavior.
  # The lockfile `rustup.stable` pin (a date, e.g. 2026-04-14) selects the
  # exact nightly-of-record toolchain; absent the pin we install bare stable.
  _rustup_stable_spec="stable"
  if [ -n "$_rustup_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to bare stable -- safe, the toolchain still installs.
    _rustup_stable_date="$("$_rustup_jq" -r '(.rustup // {}).stable // empty' "$_rustup_lockfile" 2>/dev/null)" || true
    [ -n "$_rustup_stable_date" ] && _rustup_stable_spec="stable-${_rustup_stable_date}"
  fi
  if "$_rustup_bin" toolchain list 2>/dev/null | grep -q "^${_rustup_stable_spec}"; then
    say -l rustup "${_rustup_stable_spec} toolchain already present"
  else
    say -l rustup "installing ${_rustup_stable_spec} toolchain for cargo-binstall fallback"
    "$_rustup_bin" toolchain install "${_rustup_stable_spec}" --no-self-update
  fi
fi
