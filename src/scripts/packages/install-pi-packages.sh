#!/usr/bin/env bash
# Idempotently converges the declarative pi coding agent npm package set.
#
# Reads the desired packages from src/modules/packages/desired.json (host-keyed
# single source of truth; versions pinned by the lockfile `pi` section),
# compares against the packages pi actually manages (its settings.json registry
# unioned with the npm install record), installs missing or drifted packages,
# and removes undesired ones.
#
# Args: $1 = jq bin, $2 = pi bin, $3 = awk bin, $4 = desired packages JSON
set -euo pipefail

# SC2094 avoidance: trap-based cleanup eliminates read/write-same-file
# pipeline warnings — temp files are cleaned on EXIT instead of inline.
_ipp_desired=""
_ipp_installed=""
_ipp_to_remove=""
_ipp_to_install=""
_ipp_installed=""
_ipp_installed_versions=""
_ipp_to_remove=""
_ipp_to_install=""
_cleanup_ipp() { rm -f "$_ipp_desired" "$_ipp_installed" "$_ipp_installed.dedup" "$_ipp_installed_versions" "$_ipp_to_remove" "$_ipp_to_install"; }
trap _cleanup_ipp EXIT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_jq_bin="$1"
_pi_bin="$2"
_gawk_bin="$3"
_ipp_desired_json="$4"

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

# Desired-state list from src/modules/packages/desired.json: an array of
# {"name": <npm package>} objects.  Only packages not available in nixpkgs
# belong here.  Versions are pinned from the lockfile `pi` section (see
# _ipp_install_spec).
_ipp_desired="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ipp_desired_json" |
  "$_jq_bin" -r '.[].name' >"$_ipp_desired" ||
  die -l pi "could not parse the desired pi package list"

# Get the packages pi actually manages.  The authoritative registry is
# ~/.pi/agent/settings.json (`packages` holds specs such as
# "npm:@scope/pkg@1.2.3"); it is unioned with the physical install record in
# ~/.pi/agent/npm/package.json.  Directory listing is NOT a valid source: the
# npm tree also contains node_modules and other non-package entries.
_ipp_settings_json="$HOME/.pi/agent/settings.json"
_ipp_install_record="$HOME/.pi/agent/npm/package.json"
_ipp_installed="$(mktemp)"
_ipp_installed_versions="$(mktemp)"
if [ -f "$_ipp_settings_json" ]; then
  # Strip the npm scheme and any trailing @version.  A scoped name keeps its
  # leading @ because the version suffix only matches an @ not followed by /.
  # shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
  if ! "$_jq_bin" -r '(.packages // [])[] | sub("^npm:"; "") | sub("@[^/@]*$"; "")' "$_ipp_settings_json" >>"$_ipp_installed"; then
    die -l pi "could not parse the pi package registry: $_ipp_settings_json"
  fi
fi
if [ -f "$_ipp_install_record" ]; then
  # check-suppress:suppression_doc: parse failure on the install record is a hard error -- reported by the die below.
  if ! "$_jq_bin" -r '.dependencies // {} | keys[]' "$_ipp_install_record" >>"$_ipp_installed"; then
    die -l pi "could not parse the pi install record: $_ipp_install_record"
  fi
  # name<TAB>version, used for version-aware reconciliation against the pin.
  if ! "$_jq_bin" -r '.dependencies // {} | to_entries[] | "\(.key)\t\(.value)"' "$_ipp_install_record" >"$_ipp_installed_versions"; then
    die -l pi "could not parse the pi install record: $_ipp_install_record"
  fi
fi
# A package can appear in both records; collapse duplicates so it is neither
# installed nor removed twice.
if [ -s "$_ipp_installed" ]; then
  # shellcheck disable=SC2016 # reason: awk program body must not be expanded by shell
  "$_gawk_bin" '!seen[$0]++' "$_ipp_installed" >"$_ipp_installed.dedup" && mv "$_ipp_installed.dedup" "$_ipp_installed"
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
  if ! "$_pi_bin" remove "npm:$_ipp_pkg"; then
    die -l pi "'$_pi_bin remove npm:$_ipp_pkg' failed"
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
      | if ($e | type) == "string" then "npm:\($p)@\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "git+\($e.source)#\($e.rev)"
        else "" end
    ' "$_ipp_lockfile" 2>/dev/null)" || true
    [ -n "$_ipp_pin" ] && _ipp_spec="$_ipp_pin"
  fi
  say -l pi "installing $_ipp_spec"
  if ! "$_pi_bin" install "$_ipp_spec" --no-approve; then
    die -l pi "'$_pi_bin install $_ipp_spec' failed"
  fi
  say -l pi "$_ipp_pkg installed successfully"
done <"$_ipp_to_install"
