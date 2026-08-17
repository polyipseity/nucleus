#!/usr/bin/env bash
# Idempotently converges the declarative bun global package set.
set -euo pipefail

# SC2094 avoidance: trap-based cleanup eliminates read/write-same-file
# pipeline warnings — temp files are cleaned on EXIT instead of inline.
_ibp_desired=""
_ibp_installed=""
_ibp_to_remove=""
_ibp_to_install=""
_cleanup_ibp() { rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_installed_versions" "$_ibp_to_remove" "$_ibp_to_install"; }
trap _cleanup_ibp EXIT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_jq_bin="$1"
_bun_bin="$2"

# Add bun's directory to PATH so bun is callable and child processes
# can find it.
_bun_bin_dir="$(dirname "$_bun_bin")"
PATH="$_bun_bin_dir:$PATH"
export PATH

if [ ! -x "$_bun_bin" ]; then
  die -l bun "$_bun_bin not found in nix store; cannot install bun global packages"
fi

# Read version pins from the consolidated lockfile so installs are
# reproducible (closes the drift root cause).  Falls back to unpinned
# install if the lockfile is unavailable (best-effort, mirrors Windows
# Invoke-BunSetup.ps1).
_ibp_lockfile=""
# check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
_ibp_repo_root="$(derive_repo_root 2>/dev/null || true)"
if [ -n "$_ibp_repo_root" ] && [ -f "$_ibp_repo_root/src/lockfiles/lockfile.json" ]; then
  _ibp_lockfile="$_ibp_repo_root/src/lockfiles/lockfile.json"
fi

# Declarative desired-state list.  One package per line.
# Add a package name here to install it; remove it to trigger uninstall
# on the next apply.  Only add packages absent from nixpkgs and
# cargo-binstall (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
# Versions are pinned from the lockfile `bun` section (see _ibp_install_spec).
_ibp_desired="$(mktemp)"
printf '%s\n' \
  'clawhub' \
  >"$_ibp_desired"

# Get actually installed global packages from bun's authoritative package
# registry (zap-style: remove any installed package absent from the desired
# list, regardless of prior managed state).  The global package.json is
# bun's canonical record of all globally-installed packages.
_ibp_global_json="$HOME/.bun/install/global/package.json"
_ibp_installed="$(mktemp)"
_ibp_installed_versions="$(mktemp)"
if [ -f "$_ibp_global_json" ]; then
  # check-suppress:suppression_doc: parse failure on a malformed or partially-written file treats the installed set as empty -- safe because desired packages will simply be re-installed on the next run.
  "$_jq_bin" -r '.dependencies // {} | keys[]' "$_ibp_global_json" >"$_ibp_installed" || true
  # name<TAB>version for version-aware reconciliation against the lockfile pin.
  # check-suppress:suppression_doc: parse failure on a malformed or partially-written file treats the installed set as empty -- safe because desired packages will simply be re-installed on the next run.
  "$_jq_bin" -r '.dependencies // {} | to_entries[] | "\(.key)\t\(.value)"' "$_ibp_global_json" >"$_ibp_installed_versions" || true
fi

# Packages installed but not desired: zap-style removal.
# Mirrors homebrew cleanup = "zap": removes anything installed but absent
# from the declared desired set, regardless of how it was installed.
_ibp_to_remove="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  if ! grep -qxF "$_ibp_pkg" "$_ibp_desired"; then
    printf '%s\n' "$_ibp_pkg" >>"$_ibp_to_remove"
  fi
done <"$_ibp_installed"

# Desired packages not yet in bun's global package.json, whose binary is
# absent from ~/.bun/bin, or installed at a version different from the
# lockfile pin (version-aware reconciliation).  Binary name = last path
# component after '/' so @scope/name becomes name (bun uses the unscoped
# basename as the binary name).
_ibp_to_install="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  _ibp_bin="${_ibp_pkg##*/}"
  _ibp_lock_pin=""
  if [ -n "$_ibp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the package is then installed unpinned.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ibp_lock_pin="$("$_jq_bin" -r --arg p "$_ibp_pkg" '
      (.bun // {})[$p] as $e
      | if ($e | type) == "string" then $e
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then $e.rev
        else "" end
    ' "$_ibp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the package is then installed unpinned.
  fi
  _ibp_installed_version="$(awk -F'\t' -v p="$_ibp_pkg" '$1 == p { print $2; exit }' "$_ibp_installed_versions")"
  _ibp_needs_install=0
  if ! grep -qxF "$_ibp_pkg" "$_ibp_installed"; then
    _ibp_needs_install=1
  elif [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
    _ibp_needs_install=1
  elif [ -n "$_ibp_lock_pin" ] && [ "$_ibp_installed_version" != "$_ibp_lock_pin" ]; then
    _ibp_needs_install=1
  fi
  [ "$_ibp_needs_install" -eq 1 ] && printf '%s\n' "$_ibp_pkg" >>"$_ibp_to_install"
done <"$_ibp_desired"

# Remove packages no longer in the desired list.
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  say -l bun "removing $_ibp_pkg"
  if ! "$_bun_bin" remove -g "$_ibp_pkg"; then
    die -l bun "'$_bun_bin remove -g $_ibp_pkg' failed"
  fi
done <"$_ibp_to_remove"

# Install packages whose binary is absent from ~/.bun/bin, or whose
# installed version differs from the lockfile pin (re-install to converge).
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  _ibp_spec="$_ibp_pkg"
  if [ -n "$_ibp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the package still installs.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ibp_pin="$("$_jq_bin" -r --arg p "$_ibp_pkg" '
      (.bun // {})[$p] as $e
      | if ($e | type) == "string" then "\($p)@\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "git+\($e.source)#\($e.rev)"
        else "" end
    ' "$_ibp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the package still installs.
    [ -n "$_ibp_pin" ] && _ibp_spec="$_ibp_pin"
  fi
  say -l bun "installing $_ibp_spec"
  if ! "$_bun_bin" install -g --ignore-scripts "$_ibp_spec"; then
    die -l bun "'$_bun_bin install -g $_ibp_spec' failed"
  fi
  _ibp_bin="${_ibp_pkg##*/}"
  if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] &&
    [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
    die -l bun "$_ibp_pkg installed but binary '$_ibp_bin' not found in '$HOME/.bun/bin'"
  fi
  say -l bun "$_ibp_pkg installed successfully"
done <"$_ibp_to_install"
