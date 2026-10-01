#!/usr/bin/env bash
# Converges the declarative bun global package set from
# src/modules/packages/desired.json, with versions pinned by the lockfile `bun`
# section.
#
# Positional args: <jq-bin> <bun-bin> <awk-bin> <node-gyp-bin> <python3-bin> <make-bin> <desired-json>
# The node-gyp toolchain args exist because allowlisted packages run lifecycle
# scripts (see `src/lockfiles/lifecycle-allowlist.json`), and bun synthesises a
# `node-gyp rebuild` for native dependencies whose prebuild metadata it ignores.
set -euo pipefail

# SC2094 avoidance: the EXIT trap cleans up temp files instead of inline.
_ibp_desired=""
_ibp_desired_names=""
_ibp_installed=""
_ibp_installed_versions=""
_ibp_to_remove=""
_ibp_to_install=""
_cleanup_ibp() { rm -f "$_ibp_desired" "$_ibp_desired_names" "$_ibp_installed" "$_ibp_installed_versions" "$_ibp_to_remove" "$_ibp_to_install"; }
trap _cleanup_ibp EXIT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_jq_bin="$1"
_bun_bin="$2"
_gawk_bin="$3"
# The activation PATH provides neither a Python interpreter nor make, so the
# toolchain is passed in explicitly.
_ibp_node_gyp_bin="$4"
_ibp_python3_bin="$5"
_ibp_make_bin="$6"
_ibp_desired_json="$7"

# bun must be callable and the lifecycle-script children (node-gyp -> python3,
# make) must resolve their tools.
_bun_bin_dir="$(dirname "$_bun_bin")"
_ibp_node_gyp_dir="$(dirname "$_ibp_node_gyp_bin")"
_ibp_python3_dir="$(dirname "$_ibp_python3_bin")"
_ibp_make_dir="$(dirname "$_ibp_make_bin")"
PATH="$_bun_bin_dir:$_ibp_node_gyp_dir:$_ibp_python3_dir:$_ibp_make_dir:$PATH"
export PATH

if [ ! -x "$_bun_bin" ]; then
  die -l bun "$_bun_bin not found in nix store; cannot install bun global packages"
fi
if [ ! -x "$_ibp_node_gyp_bin" ]; then
  die -l bun "$_ibp_node_gyp_bin not found in nix store; cannot rebuild native dependencies of allowlisted bun packages"
fi
if [ ! -x "$_ibp_python3_bin" ]; then
  die -l bun "$_ibp_python3_bin not found in nix store; node-gyp requires a Python interpreter"
fi
if [ ! -x "$_ibp_make_bin" ]; then
  die -l bun "$_ibp_make_bin not found in nix store; node-gyp requires make"
fi

# WHY: node-gyp is pointed at the store wrapper rather than letting bun fetch
# its own, and at the store's Python rather than searching PATH where an
# interpreter may be stdlib-less or absent. The nixpkgs wrapper already exports
# npm_config_nodedir, so no headers are downloaded.
export npm_config_node_gyp="$_ibp_node_gyp_bin"
export npm_config_python="$_ibp_python3_bin"

# Pins come from the lockfile, falling back to an unpinned install when it is
# unavailable (mirrors Windows Invoke-BunSetup.ps1).
_ibp_lockfile=""
# check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
_ibp_repo_root="$(derive_repo_root 2>/dev/null || true)"
if [ -n "$_ibp_repo_root" ] && [ -f "$_ibp_repo_root/src/lockfiles/lockfile.json" ]; then
  _ibp_lockfile="$_ibp_repo_root/src/lockfiles/lockfile.json"
fi
if [ -n "$_ibp_repo_root" ] && [ -f "$_ibp_repo_root/src/lockfiles/lifecycle-allowlist.json" ]; then
  _ibp_lifecycle_allowlist="$_ibp_repo_root/src/lockfiles/lifecycle-allowlist.json"
fi

# An array of {"name": <npm package>, "binary"?: <installed binary name>}
# objects, holding only the packages absent from nixpkgs and cargo-binstall
# (preference: nixpkgs > cargo binstall > cargo > bun > uv). Written as
# "<name>\t<binary>" so an explicit binary override wins; the default is the
# unscoped package basename.
_ibp_desired="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ibp_desired_json" |
  "$_jq_bin" -r '.[] | "\(.name)\t\(if (.binary // "") == "" then (.name | split("/") | last) else .binary end)"' >"$_ibp_desired" ||
  die -l bun "could not parse the desired bun package list"
_ibp_desired_names="$(mktemp)"
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
"$_gawk_bin" -F'\t' '{print $1}' "$_ibp_desired" >"$_ibp_desired_names"

# Installed packages come from bun's global package.json, its canonical record.
_ibp_global_json="$HOME/.bun/install/global/package.json"
_ibp_installed="$(mktemp)"
_ibp_installed_versions="$(mktemp)"
if [ -f "$_ibp_global_json" ]; then
  # check-suppress:suppression_doc: parse failure on a malformed or partially-written file treats the installed set as empty -- safe because desired packages will simply be re-installed on the next run.
  "$_jq_bin" -r '.dependencies // {} | keys[]' "$_ibp_global_json" >"$_ibp_installed" || true
  # name<TAB>version for version-aware reconciliation against the pin.
  # check-suppress:suppression_doc: parse failure on a malformed or partially-written file treats the installed set as empty -- safe because desired packages will simply be re-installed on the next run.
  "$_jq_bin" -r '.dependencies // {} | to_entries[] | "\(.key)\t\(.value)"' "$_ibp_global_json" >"$_ibp_installed_versions" || true
fi

# Removal mirrors homebrew zap: anything installed but absent from the desired
# set goes, regardless of how it was installed.
_ibp_to_remove="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  if ! grep -qxF "$_ibp_pkg" "$_ibp_desired_names"; then
    printf '%s\n' "$_ibp_pkg" >>"$_ibp_to_remove"
  fi
done <"$_ibp_installed"

# Desired packages absent from the global package.json, whose binary is missing
# from ~/.bun/bin, or installed at a version other than the pin. The binary name
# is the last path component, so @scope/name becomes name.
_ibp_to_install="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _ibp_bin="$("$_gawk_bin" -F'\t' -v p="$_ibp_pkg" '$1 == p { print $2; exit }' "$_ibp_desired")"
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
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _ibp_installed_version="$("$_gawk_bin" -F'\t' -v p="$_ibp_pkg" '$1 == p { print $2; exit }' "$_ibp_installed_versions")"
  _ibp_needs_install=0
  if ! grep -qxF "$_ibp_pkg" "$_ibp_installed"; then
    _ibp_needs_install=1
  elif [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
    _ibp_needs_install=1
  elif [ -n "$_ibp_lock_pin" ] && [ "$_ibp_installed_version" != "$_ibp_lock_pin" ]; then
    _ibp_needs_install=1
  fi
  [ "$_ibp_needs_install" -eq 1 ] && printf '%s\n' "$_ibp_pkg" >>"$_ibp_to_install"
done <"$_ibp_desired_names"

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
  # Allowlisted packages run lifecycle scripts (postinstall and friends) that
  # some packages need for native module compilation and model downloads.
  _ibp_allow_lifecycle=0
  if [ -n "$_ibp_lifecycle_allowlist" ]; then
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    if "$_jq_bin" -e --arg p "$_ibp_pkg" '(.[$p] // null) != null' "$_ibp_lifecycle_allowlist" >/dev/null 2>&1; then
      _ibp_allow_lifecycle=1
    fi
  fi
  # WHY: the machine-wide bunfig.toml sets `install.linker = "isolated"`, and bun
  # then links a global package's binaries only into the global node_modules/.bin,
  # leaving $BUN_INSTALL/bin empty so the CLI never reaches PATH
  # (oven-sh/bun#30450). Global installs are pinned back to the hoisted linker,
  # which is where the existence check below expects the binary.
  if [ "$_ibp_allow_lifecycle" -eq 1 ]; then
    say -l bun "$_ibp_pkg: lifecycle scripts allowed (in lifecycle-allowlist)"
    if ! "$_bun_bin" install -g --linker hoisted "$_ibp_spec"; then
      die -l bun "'$_bun_bin install -g --linker hoisted $_ibp_spec' failed"
    fi
  else
    if ! "$_bun_bin" install -g --linker hoisted --ignore-scripts "$_ibp_spec"; then
      die -l bun "'$_bun_bin install -g --linker hoisted --ignore-scripts $_ibp_spec' failed"
    fi
  fi
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _ibp_bin="$("$_gawk_bin" -F'\t' -v p="$_ibp_pkg" '$1 == p { print $2; exit }' "$_ibp_desired")"
  if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] &&
    [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
    die -l bun "$_ibp_pkg installed but binary '$_ibp_bin' not found in '$HOME/.bun/bin'"
  fi
  say -l bun "$_ibp_pkg installed successfully"
done <"$_ibp_to_install"
