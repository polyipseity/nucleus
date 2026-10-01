#!/usr/bin/env bash
# Managed cargo-binstall package convergence (install + zap). Reads the desired crate
# list from src/modules/packages/desired.json at activation time; versions are pinned by
# the lockfile `cargo-binstall` section. Install priority: nixpkgs > cargo binstall >
# cargo > bun > uv.
#
# External tools MUST be passed as absolute store-path arguments: ShellCheck cannot
# verify PATH-resolved commands at activation time, so bare commands are forbidden and
# the activation-tool-resolution check (step 17) enforces it. Runtime probing of
# ~/.cargo/bin is prohibited.
set -euo pipefail

# WHY: the cleanup trap runs on EXIT instead of inline, which also clears the SC2094
# read/write-same-file warning. Every name it touches is declared here so it stays safe
# under `set -u` when it fires before the mktemp assignments have run.
_icp_desired=""
_icp_installed=""
_icp_installed_versions=""
_icp_to_remove=""
_icp_to_install=""
_cleanup_icp() { rm -f "$_icp_desired" "$_icp_installed" "$_icp_installed_versions" "$_icp_to_remove" "$_icp_to_install"; }
trap _cleanup_icp EXIT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_icp_jq_bin="$1"
_icp_gawk_bin="$2"
_icp_desired_crates_json="$3"
_icp_cargo_bin="$4"
_icp_cargo_binstall_bin="$5"
# WHY: ${6:-} not $6, because sccache is optional and a caller with no sccache store path must be able to omit the argument; under `set -u` a bare `$6` aborted before the optionality check could run.
_icp_sccache_bin="${6:-}"
if [ -z "$_icp_cargo_binstall_bin" ]; then
  die -l cargo-binstall "cargo-binstall store-path bin argument (arg 5) is required"
fi

# Pins come from the lockfile so installs are reproducible. An unavailable lockfile falls back to an unpinned install, mirroring Windows Invoke-CargoBinstallSetup.ps1.
_icp_lockfile=""
_icp_repo_root="$(derive_repo_root 2>/dev/null || true)" # check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
if [ -n "$_icp_repo_root" ] && [ -f "$_icp_repo_root/src/lockfiles/lockfile.json" ]; then
  _icp_lockfile="$_icp_repo_root/src/lockfiles/lockfile.json"
fi

# Prepend nixpkgs cargo's directory to PATH so `cargo` is available.
PATH="$PATH:${_icp_cargo_bin%/*}"
export PATH

# RUSTC_WRAPPER points at the absolute sccache store path so cargo, invoked by
# cargo-binstall's compilation fallback, finds sccache even though Home Manager activation
# resets PATH. An empty arg simply leaves the wrapper unset.
if [ -n "$_icp_sccache_bin" ]; then
  RUSTC_WRAPPER="$_icp_sccache_bin"
  export RUSTC_WRAPPER
fi

# Desired crates: an array of {"name": <crate>, "binary"?: <installed binary name>}
# objects, and an empty array means this host manages none. The optional binary name is
# consumed on Windows (Invoke-CargoBinstallSetup); POSIX converges on the crate name.
_icp_desired="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_icp_desired_crates_json" | "$_icp_jq_bin" -r '.[].name' >"$_icp_desired"

# Installed crates from `cargo install --list`, whose header lines read "crate-name vX.Y.Z:".
_icp_installed="$(mktemp)"
_icp_installed_versions="$(mktemp)"
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
cargo install --list 2>/dev/null | "$_icp_gawk_bin" '/^[a-zA-Z0-9_-]+ v/{print $1}' >"$_icp_installed" || true # check-suppress:suppression_doc: cargo install --list may fail if ~/.cargo uninitialised
# name<TAB>version for version-aware reconciliation against the lockfile pin.
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
cargo install --list 2>/dev/null | "$_icp_gawk_bin" '/^[a-zA-Z0-9_-]+ v/{gsub(/:$/,"",$2); print $1"\t"$2}' >"$_icp_installed_versions" || true # check-suppress:suppression_doc: cargo install --list may fail if ~/.cargo uninitialised

# Crates installed but not desired: zap-style removal.
_icp_to_remove="$(mktemp)"
while IFS= read -r _icp_crate; do
  [ -z "$_icp_crate" ] && continue
  if ! grep -qxF "$_icp_crate" "$_icp_desired"; then
    printf '%s\n' "$_icp_crate" >>"$_icp_to_remove"
  fi
done <"$_icp_installed"

# Desired crates absent or installed at a version other than the pin, so they are reinstalled.
_icp_to_install="$(mktemp)"
while IFS= read -r _icp_crate; do
  [ -z "$_icp_crate" ] && continue
  _icp_lock_pin=""
  if [ -n "$_icp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the crate is then installed unpinned.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _icp_lock_pin="$("$_icp_jq_bin" -r --arg p "$_icp_crate" '
      (.["cargo-binstall"] // {})[$p] as $e
      | if ($e | type) == "string" then $e
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then $e.rev
        else "" end
    ' "$_icp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the crate is then installed unpinned.
  fi
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _icp_installed_version="$("$_icp_gawk_bin" -F'\t' -v p="$_icp_crate" '$1 == p { print $2; exit }' "$_icp_installed_versions")"
  _icp_needs_install=0
  if ! grep -qxF "$_icp_crate" "$_icp_installed"; then
    _icp_needs_install=1
  elif [ -n "$_icp_lock_pin" ] && [ "$_icp_installed_version" != "$_icp_lock_pin" ]; then
    _icp_needs_install=1
  fi
  [ "$_icp_needs_install" -eq 1 ] && printf '%s\n' "$_icp_crate" >>"$_icp_to_install"
done <"$_icp_desired"

# Remove crates not in the desired list.
while IFS= read -r _icp_crate; do
  [ -z "$_icp_crate" ] && continue
  say -l cargo-binstall "removing $_icp_crate"
  if ! cargo uninstall "$_icp_crate"; then
    die -l cargo-binstall "'cargo uninstall $_icp_crate' failed"
  fi
  say -l cargo-binstall "'$_icp_crate' removed"
done <"$_icp_to_remove"

# Install desired crates missing or drifted from the pin.
while IFS= read -r _icp_crate; do
  [ -z "$_icp_crate" ] && continue
  _icp_spec="$_icp_crate"
  if [ -n "$_icp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the crate still installs.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _icp_pin="$("$_icp_jq_bin" -r --arg p "$_icp_crate" '
      (.["cargo-binstall"] // {})[$p] as $e
      | if ($e | type) == "string" then "\($p)@\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "--git \($e.source) --rev \($e.rev) \($p)"
        else "" end
    ' "$_icp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the crate still installs.
    [ -n "$_icp_pin" ] && _icp_spec="$_icp_pin"
  fi
  say -l cargo-binstall "installing $_icp_spec"
  # shellcheck disable=SC2086 # reason: _icp_spec is a single crate@version token or a --git/--rev/crate triple, intentionally unquoted
  if ! "$_icp_cargo_binstall_bin" --no-confirm $_icp_spec; then
    die -l cargo-binstall "'cargo-binstall $_icp_spec' failed"
  fi
  say -l cargo-binstall "'$_icp_crate' installed"
done <"$_icp_to_install"

if [ ! -s "$_icp_to_remove" ] && [ ! -s "$_icp_to_install" ]; then
  say -l cargo-binstall "all managed packages already converged — skipping"
fi
