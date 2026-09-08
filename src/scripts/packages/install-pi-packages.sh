#!/usr/bin/env bash
# Idempotently converges the declarative pi coding agent npm package set.
#
# Reads desired packages from the lockfile `pi` section, compares against
# actually installed packages in ~/.pi/agent/npm/, installs missing or
# drifted packages, and removes undesired ones.
#
# Args: $1 = jq bin, $2 = pi bin, $3 = awk bin
set -euo pipefail

# SC2094 avoidance: trap-based cleanup eliminates read/write-same-file
# pipeline warnings — temp files are cleaned on EXIT instead of inline.
_ipp_desired=""
_ipp_installed=""
_ipp_to_remove=""
_ipp_to_install=""
_cleanup_ipp() { rm -f "$_ipp_desired" "$_ipp_installed" "$_ipp_installed_versions" "$_ipp_to_remove" "$_ipp_to_install"; }
trap _cleanup_ipp EXIT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_jq_bin="$1"
_pi_bin="$2"
_gawk_bin="$3"

# Add pi's directory to PATH so pi is callable and child processes
# can find it.
_pi_bin_dir="$(dirname "$_pi_bin")"
PATH="$_pi_bin_dir:$PATH"
export PATH

if [ ! -x "$_pi_bin" ]; then
  die -l pi "$_pi_bin not found in nix store; cannot install pi packages"
fi

# Read version pins from the consolidated lockfile so installs are
# reproducible (closes the drift root cause).
_ipp_lockfile=""
# check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
_ipp_repo_root="$(derive_repo_root 2>/dev/null || true)"
if [ -n "$_ipp_repo_root" ] && [ -f "$_ipp_repo_root/src/lockfiles/lockfile.json" ]; then
  _ipp_lockfile="$_ipp_repo_root/src/lockfiles/lockfile.json"
fi

# Declarative desired-state list.  One package per line.
# Add a package name here to install it; remove it to trigger uninstall
# on the next apply.  Only add packages not available in nixpkgs.
# Versions are pinned from the lockfile `pi` section (see _ipp_install_spec).
_ipp_desired="$(mktemp)"
printf '%s\n' \
  '@juicesharp/rpiv-ask-user-question' \
  '@narumitw/pi-plan-mode' \
  'pi-background-tasks' \
  'pi-extmgr' \
  'pi-goal-x' \
  'pi-memory' \
  'pi-powerline-footer' \
  'pi-simplify' \
  'pi-subagents' \
  'pi-web-access' \
  >"$_ipp_desired"

# Get actually installed packages from ~/.pi/agent/npm/ directory listing.
# Each subdirectory name is an installed package (npm flat install layout).
_ipp_npm_dir="$HOME/.pi/agent/npm"
_ipp_installed="$(mktemp)"
_ipp_installed_versions="$(mktemp)"
if [ -d "$_ipp_npm_dir" ]; then
  for _ipp_entry in "$_ipp_npm_dir"/*; do
    [ -d "$_ipp_entry" ] || continue
    _ipp_name="$(basename "$_ipp_entry")"
    printf '%s\n' "$_ipp_name" >>"$_ipp_installed"
    # Read version from package.json if available.
    _ipp_pkg_json="$_ipp_entry/package.json"
    if [ -f "$_ipp_pkg_json" ]; then
      # check-suppress:suppression_doc: parse failure on a malformed package.json treats version as unknown -- safe because the package will be re-installed.
      _ipp_ver="$("$_jq_bin" -r '.version // ""' "$_ipp_pkg_json" 2>/dev/null)" || true
      printf '%s\t%s\n' "$_ipp_name" "$_ipp_ver" >>"$_ipp_installed_versions"
    fi
  done
fi

# Packages installed but not desired: zap-style removal.
# Mirrors homebrew cleanup = "zap": removes anything installed but absent
# from the declared desired set, regardless of how it was installed.
_ipp_to_remove="$(mktemp)"
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  if ! grep -qxF "$_ipp_pkg" "$_ipp_desired"; then
    printf '%s\n' "$_ipp_pkg" >>"$_ipp_to_remove"
  fi
done <"$_ipp_installed"

# Desired packages not yet installed, or installed at a version different
# from the lockfile pin (version-aware reconciliation).
_ipp_to_install="$(mktemp)"
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  _ipp_lock_pin=""
  if [ -n "$_ipp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the package is then installed unpinned.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ipp_lock_pin="$("$_jq_bin" -r --arg p "$_ipp_pkg" '
      (.pi // {})[$p] as $e
      | if ($e | type) == "string" then $e
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then $e.rev
        else "" end
    ' "$_ipp_lockfile" 2>/dev/null)" || true
  fi
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _ipp_installed_version="$("$_gawk_bin" -F'\t' -v p="$_ipp_pkg" '$1 == p { print $2; exit }' "$_ipp_installed_versions")"
  _ipp_needs_install=0
  if ! grep -qxF "$_ipp_pkg" "$_ipp_installed"; then
    _ipp_needs_install=1
  elif [ -n "$_ipp_lock_pin" ] && [ "$_ipp_installed_version" != "$_ipp_lock_pin" ]; then
    _ipp_needs_install=1
  fi
  [ "$_ipp_needs_install" -eq 1 ] && printf '%s\n' "$_ipp_pkg" >>"$_ipp_to_install"
done <"$_ipp_desired"

# Remove packages no longer in the desired list.
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  say -l pi "removing $_ipp_pkg"
  if ! "$_pi_bin" remove "npm:$_ipp_pkg" 2>/dev/null; then
    # Best-effort removal: warn but don't abort.
    warn -l pi "failed to remove $_ipp_pkg (may not be installed)"
  fi
done <"$_ipp_to_remove"

# Install packages not yet installed, or at wrong version.
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  _ipp_spec="npm:$_ipp_pkg"
  if [ -n "$_ipp_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the package still installs.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ipp_pin="$("$_jq_bin" -r --arg p "$_ipp_pkg" '
      (.pi // {})[$p] as $e
      | if ($e | type) == "string" then "\($p)@\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "git+\($e.source)#\($e.rev)"
        else "" end
    ' "$_ipp_lockfile" 2>/dev/null)" || true
    [ -n "$_ipp_pin" ] && _ipp_spec="$_ipp_pin"
  fi
  say -l pi "installing $_ipp_spec"
  # check-suppress:suppression_doc: pi install may warn about project trust; best-effort convergence.
  if ! "$_pi_bin" install "$_ipp_spec" --no-approve 2>/dev/null; then
    warn -l pi "failed to install $_ipp_spec (will retry on next apply)"
  else
    say -l pi "$_ipp_pkg installed successfully"
  fi
done <"$_ipp_to_install"
