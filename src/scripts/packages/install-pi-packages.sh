#!/usr/bin/env bash
# Converges the declarative pi package set from src/modules/packages/desired.json,
# with versions pinned by the lockfile `pi` section.
#
# Args: $1 = jq bin, $2 = pi bin, $3 = awk bin, $4 = sed bin,
#       $5 = desired packages JSON, $6 = bun bin dir
set -euo pipefail

# SC2094 avoidance: the EXIT trap cleans up temp files instead of inline.
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
_sed_bin="$4"
_ipp_desired_json="$5"
_ipp_bun_bin="$6"

# pi runs the runner, and bun must be on PATH because pi spawns the bare
# command "bun" for every npm: install (npmCommand in
# src/users/default/pi/settings.json).
_pi_bin_dir="$(dirname "$_pi_bin")"
_sed_bin_dir="$(dirname "$_sed_bin")"
PATH="$_pi_bin_dir:$_ipp_bun_bin:$_sed_bin_dir:$PATH"
export PATH

if [ ! -x "$_pi_bin" ]; then
  die -l pi "$_pi_bin not found in nix store; cannot install pi packages"
fi
if ! "$_ipp_bun_bin/bun" --version >/dev/null; then
  die -l pi "$_ipp_bun_bin/bun is not runnable; pi spawns 'bun' for npm-installs"
fi

_ipp_lockfile=""
# check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
_ipp_repo_root="$(derive_repo_root 2>/dev/null || true)"
if [ -n "$_ipp_repo_root" ] && [ -f "$_ipp_repo_root/src/lockfiles/lockfile.json" ]; then
  _ipp_lockfile="$_ipp_repo_root/src/lockfiles/lockfile.json"
fi

# An array of {"name": <npm package>} objects holding the packages nixpkgs
# does not have.
_ipp_desired="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ipp_desired_json" |
  "$_jq_bin" -r '.[].name' >"$_ipp_desired" ||
  die -l pi "could not parse the desired pi package list"

# The packages pi actually manages: ~/.pi/agent/settings.json (specs such as
# "npm:@scope/pkg@1.2.3") unioned with the install record in
# ~/.pi/agent/npm/package.json. A directory listing is not a valid source, since
# the npm tree also holds node_modules.
_ipp_settings_json="$HOME/.pi/agent/settings.json"
_ipp_install_record="$HOME/.pi/agent/npm/package.json"
_ipp_installed="$(mktemp)"
_ipp_installed_versions="$(mktemp)"
if [ -f "$_ipp_settings_json" ]; then
  # Strip the npm scheme and any trailing @version. A scoped name keeps its
  # leading @, since the version suffix only matches an @ not followed by /.
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
# A package can appear in both records, so collapse duplicates.
if [ -s "$_ipp_installed" ]; then
  # shellcheck disable=SC2016 # reason: awk program body must not be expanded by shell
  "$_gawk_bin" '!seen[$0]++' "$_ipp_installed" >"$_ipp_installed.dedup" && mv "$_ipp_installed.dedup" "$_ipp_installed"
fi

# Removal mirrors homebrew zap: anything installed but absent from the desired
# set goes, regardless of how it was installed.
_ipp_to_remove="$(mktemp)"
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  if ! grep -qxF "$_ipp_pkg" "$_ipp_desired"; then
    printf '%s\n' "$_ipp_pkg" >>"$_ipp_to_remove"
  fi
done <"$_ipp_installed"

# Desired packages missing or installed at a version other than the pin.
_ipp_to_install="$(mktemp)"
while IFS= read -r _ipp_pkg; do
  [ -z "$_ipp_pkg" ] && continue
  _ipp_lock_pin=""
  if [ -n "$_ipp_lockfile" ]; then
    # The pin is tagged by kind: a string pin is a released version, an object
    # pin is a repository revision (a git install has no comparable version).
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ipp_lock_pin="$("$_jq_bin" -r --arg p "$_ipp_pkg" '
      (.pi // {})[$p] as $e
      | if ($e | type) == "string" then "version:\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "rev:\($e.rev)"
        else "" end
    ' "$_ipp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the package is then installed unpinned
  fi
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _ipp_installed_version="$("$_gawk_bin" -F'\t' -v p="$_ipp_pkg" '$1 == p { print $2; exit }' "$_ipp_installed_versions")"
  _ipp_needs_install=0
  if ! grep -qxF "$_ipp_pkg" "$_ipp_installed"; then
    _ipp_needs_install=1
  elif [ -n "$_ipp_lock_pin" ]; then
    case "$_ipp_lock_pin" in
    version:*)
      if [ "${_ipp_lock_pin#version:}" != "$_ipp_installed_version" ]; then
        _ipp_needs_install=1
      fi
      ;;
    # A revision pin has no comparable version, so the pinned revision must appear
    # in the recorded value.
    rev:*)
      case "$_ipp_installed_version" in
      *"${_ipp_lock_pin#rev:}"*) ;;
      *) _ipp_needs_install=1 ;;
      esac
      ;;
    esac
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
    # A revision pin becomes pi's git source form "git:<url>#<rev>". pi rejects
    # "git+<url>", so a leading git+ in the lockfile source is stripped.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _ipp_pin="$("$_jq_bin" -r --arg p "$_ipp_pkg" '
      (.pi // {})[$p] as $e
      | if ($e | type) == "string" then "npm:\($p)@\($e)"
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "git:\($e.source | sub("^git\\+"; ""))#\($e.rev)"
        else "" end
    ' "$_ipp_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the package still installs
    [ -n "$_ipp_pin" ] && _ipp_spec="$_ipp_pin"
  fi
  say -l pi "installing $_ipp_spec"
  if ! "$_pi_bin" install "$_ipp_spec" --no-approve; then
    die -l pi "'$_pi_bin install $_ipp_spec' failed"
  fi
  say -l pi "$_ipp_pkg installed successfully"
done <"$_ipp_to_install"

# Patch pi-subagents for Nix-store compatibility.
#
# A Nix package root lives in the read-only /nix/store, where bun's hoisted peer
# dependencies (@earendil-works/chord, @earendil-works/pi-server) are invisible
# to the extension's findHostPeerPackageDir upward walk. Two patches widen the
# supplement fallback and the ESM hook from the pi-server-only form they shipped
# in to any missing specifier. Each is idempotent: a grep guard checks for the
# old pattern before replacing.
_apply_pi_subagents_patches() {
  local _ext_root="$HOME/.pi/agent/npm/node_modules/pi-subagents"
  local _aliases="$_ext_root/src/runs/background/runner-aliases.ts"
  local _preload="$_ext_root/runner-server-preload.mjs"

  # Patch 1: widen the supplement fallback in runner-aliases.ts
  if [ -f "$_aliases" ] && grep -q 'readManifest(piPackageRoot)?.version === "0.85.0"' "$_aliases" 2>/dev/null; then
    # Replace the version-gated, pi-server-only supplement with a generic
    # fallback. sed line-range delete plus file insert, portable across macOS
    # and Linux.
    local _tmp _block
    _tmp="$(mktemp)"
    _block="$(mktemp)"
    cp "$_aliases" "$_tmp"
    # Write the new supplement block (3-tab indent to match surrounding code)
    cat >"$_block" <<'BLOCK'
		// Supplement missing host peers from the extension own node_modules.
		// Covers packages hoisted by bun that are invisible from the Nix store path.
		if (!target || !fs.existsSync(target)) {
			const localDir = findHostPeerPackageDir(extensionRoot, pkg);
			if (localDir) {
				const localTarget = resolvePackageSubpath(localDir, subpath);
				if (localTarget && fs.existsSync(localTarget)) {
					target = localTarget;
					supplemental.push(specifier);
				}
			}
		}
BLOCK
    # Delete the old block (comment, if, inner if, closing braces, lines 133-147)
    sed '133,147d' "$_tmp" >"$_tmp.sed" && mv "$_tmp.sed" "$_tmp"
    # Insert the new block before the "if (target" line (now at line 133)
    sed '132r '"$_block" "$_tmp" >"$_tmp.sed" && mv "$_tmp.sed" "$_tmp"
    # Update the header comment to match the new behaviour
    sed 's|Only Pi 0.85.0.s missing server exports may come from this extension.|Supplement any missing host peer from the extension own node_modules (bun-hoisted packages invisible from the Nix store path).|' "$_tmp" >"$_tmp.sed" && mv "$_tmp.sed" "$_tmp"
    mv "$_tmp" "$_aliases"
    rm -f "$_block"
    say -l pi "patched runner-aliases.ts — widened supplement fallback"
  fi

  # Patch 2: generalise the interceptor in runner-server-preload.mjs
  if [ -f "$_preload" ] && grep -q 'specifier === "@earendil-works/pi-server"' "$_preload" 2>/dev/null; then
    # Single-quoted sed expression, to avoid shell quote conflicts.
    sed 's/if (specifier === "@earendil-works\/pi-server" || specifier === "@earendil-works\/pi-server\/unix") {/if (aliases[specifier]) {/' "$_preload" >"$_preload.sed" && mv "$_preload.sed" "$_preload"
    # Update the header comment
    sed 's|Only loaded when the parent supplies Pi 0.85.0.s missing server exports.|Intercept all supplemented host peer specifiers via the JITI_ALIAS map.|' "$_preload" >"$_preload.sed" && mv "$_preload.sed" "$_preload"
    say -l pi "patched runner-server-preload.mjs — generalised interceptor"
  fi
}

_apply_pi_subagents_patches
