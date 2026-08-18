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
  #
  # Toolchain spec construction (rustup grammar): the -YYYY-MM-DD archive-date
  # suffix is ONLY valid for nightly. stable/beta are rolling channels and
  # reject a date suffix, so a lockfile pin like "2026-04-14" must NOT be
  # appended to them. We therefore install the bare channel name for
  # stable/beta and use the pin verbatim only for nightly (where the date is a
  # real archive selector). The version pin for stable/beta is recorded in the
  # lockfile for tracking only, not used in the install spec.
  _rustup_channels="stable"
  if [ -n "$_rustup_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to bare stable -- safe, the toolchain still installs.
    _rustup_channels="$("$_rustup_jq" -r '(.rustup // {}) | keys[]? // empty' "$_rustup_lockfile" 2>/dev/null)" || true
    [ -z "$_rustup_channels" ] && _rustup_channels="stable"
  fi
  while IFS= read -r _rustup_channel; do
    [ -z "$_rustup_channel" ] && continue
    _rustup_pin=""
    if [ -n "$_rustup_lockfile" ]; then
      # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
      # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to empty pin -- safe, the channel name is used as the spec.
      _rustup_pin="$("$_rustup_jq" -r --arg c "$_rustup_channel" '(.rustup // {})[$c] // empty' "$_rustup_lockfile" 2>/dev/null)" || true
    fi
    # nightly pins carry a valid -YYYY-MM-DD archive suffix and are used
    # verbatim; stable/beta are rolling channels installed by name alone
    # (their version pin is tracked, not appended to the spec).
    case "$_rustup_pin" in
    nightly*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _rustup_spec="$_rustup_pin" ;;
    nightly*) _rustup_spec="$_rustup_pin" ;;
    *) _rustup_spec="$_rustup_channel" ;;
    esac
    if "$_rustup_bin" toolchain list 2>/dev/null | grep -q "^${_rustup_spec}"; then
      say -l rustup "${_rustup_spec} toolchain already present"
    else
      say -l rustup "installing ${_rustup_spec} toolchain for cargo-binstall fallback"
      "$_rustup_bin" toolchain install "${_rustup_spec}" --no-self-update
    fi
  done <<EOF
$_rustup_channels
EOF
fi
