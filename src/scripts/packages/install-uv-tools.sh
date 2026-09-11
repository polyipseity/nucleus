#!/usr/bin/env bash
# Managed uv tool convergence (install + zap).
# Consumes tool paths and the desired tool list from
# src/modules/packages/desired.json at activation time.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_iut_uv_bin="$1"
_iut_gawk_bin="$2"
_iut_grep_bin="$3"
_iut_jq_bin="$4"
_iut_desired_json="$5"

# Read version pins from the consolidated lockfile so installs are
# reproducible (closes the drift root cause).  Falls back to unpinned
# install if the lockfile is unavailable (best-effort, mirrors Windows
# Invoke-UvSetup.ps1).
_iut_lockfile=""
_iut_repo_root="$(derive_repo_root 2>/dev/null || true)" # check-suppress:suppression_doc: repo-root auto-detection may fail on non-deployed hosts; absence falls back to unpinned install.
if [ -n "$_iut_repo_root" ] && [ -f "$_iut_repo_root/src/lockfiles/lockfile.json" ]; then
  _iut_lockfile="$_iut_repo_root/src/lockfiles/lockfile.json"
fi

# flake.lock is the authoritative record of "flake:<node>" pins, so their
# revisions are never duplicated into lockfile.json.
_iut_flake_lock=""
if [ -n "$_iut_repo_root" ] && [ -f "$_iut_repo_root/src/flake.lock" ]; then
  _iut_flake_lock="$_iut_repo_root/src/flake.lock"
fi

# Desired tools from src/modules/packages/desired.json: an array of
# {"name": <PyPI project>, "python"?: <X.Y>, "extras"?: <extra>,
# "pin"?: "flake:<node>"} objects.  Read into a temp file in
# "<name>\t<python>\t<extras>\t<pin>" format; an empty column means unset.
_iut_desired="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_iut_desired_json" |
  "$_iut_jq_bin" -r '.[] | "\(.name)\t\(.python // "")\t\(.extras // "")\t\(.pin // "")"' >"$_iut_desired" ||
  die -l uv "could not parse the desired uv tool list"

# Build name-only list for comparison (strip version column).
_iut_desired_names="$(mktemp)"
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
"$_iut_gawk_bin" '{print $1}' "$_iut_desired" >"$_iut_desired_names"

# Install required Python versions before attempting tool installs.
# Stderr suppressed: uv emits a cosmetic "Failed to patch install name"
# warning on macOS 15+ when installing older CPython that does not affect
# functionality.  Real failures surface at tool-install time below.
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _iut_python="$("$_iut_gawk_bin" -F'\t' -v tool="$_iut_tool" '$1 == tool { print $2; exit }' "$_iut_desired")"
  # check-suppress:suppression_doc: uv python install may fail if the Python version is already installed or unavailable on this platform; that's fine -- a real failure surfaces at tool-install time.
  [ -n "$_iut_python" ] && "$_iut_uv_bin" python install "$_iut_python" 2>/dev/null || true
done <"$_iut_desired_names"

# Get actually installed uv tools from `uv tool list` (zap-style: remove
# any installed tool absent from the desired list, regardless of prior
# managed state).  Parse only lines that match the documented
# "name vX.Y.Z" shape so separator/header lines (for example "-")
# cannot be misparsed as package names.
_iut_installed="$(mktemp)"
_iut_installed_versions="$(mktemp)"
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
"$_iut_uv_bin" tool list 2>/dev/null | "$_iut_gawk_bin" '/^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+v[0-9]/{print $1}' >"$_iut_installed" || true # check-suppress:suppression_doc: uv tool list may fail if no tool env initialised
# name<TAB>version (leading v stripped) for version-aware reconciliation.
# shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
"$_iut_uv_bin" tool list 2>/dev/null | "$_iut_gawk_bin" '/^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+v[0-9]/{v=$2; sub(/^v/,"",v); print $1"\t"v}' >"$_iut_installed_versions" || true # check-suppress:suppression_doc: uv tool list may fail if no tool env initialised

# Tools installed but not desired: zap-style removal.
_iut_to_remove="$(mktemp)"
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! grep -qxF "$_iut_tool" "$_iut_desired_names"; then
    printf '%s\n' "$_iut_tool" >>"$_iut_to_remove"
  fi
done <"$_iut_installed"

# Desired tools not yet installed, or installed at a version different from
# the lockfile pin (version-aware reconciliation -> reinstall).
_iut_to_install="$(mktemp)"
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  _iut_lock_pin=""
  if [ -n "$_iut_lockfile" ]; then
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the tool is then installed unpinned.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _iut_lock_pin="$("$_iut_jq_bin" -r --arg p "$_iut_tool" '
      (.uv // {})[$p] as $e
      | if ($e | type) == "string" then $e
        elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then $e.rev
        else "" end
    ' "$_iut_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile treats the pin as absent -- safe because the tool is then installed unpinned.
  fi
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _iut_installed_version="$("$_iut_gawk_bin" -F'\t' -v p="$_iut_tool" '$1 == p { print $2; exit }' "$_iut_installed_versions")"
  _iut_needs_install=0
  if ! grep -qxF "$_iut_tool" "$_iut_installed"; then
    _iut_needs_install=1
  elif [ -n "$_iut_lock_pin" ] && [ "$_iut_installed_version" != "$_iut_lock_pin" ]; then
    _iut_needs_install=1
  fi
  [ "$_iut_needs_install" -eq 1 ] && printf '%s\n' "$_iut_tool" >>"$_iut_to_install"
done <"$_iut_desired_names"

# Prune tools removed from the desired list.
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! printf '%s' "$_iut_tool" | "$_iut_grep_bin" -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    say -l uv "skipping invalid uninstall token '$_iut_tool'"
    continue
  fi
  say -l uv "uninstalling removed tool '$_iut_tool'"
  "$_iut_uv_bin" tool uninstall "$_iut_tool"
done <"$_iut_to_remove"

# Install additions.
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! printf '%s' "$_iut_tool" | "$_iut_grep_bin" -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    say -l uv "skipping invalid install token '$_iut_tool'"
    continue
  fi

  # Look up this tool's named option fields from the desired list.
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _iut_python="$("$_iut_gawk_bin" -F'\t' -v tool="$_iut_tool" '$1 == tool { print $2; exit }' "$_iut_desired")"
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _iut_extras="$("$_iut_gawk_bin" -F'\t' -v tool="$_iut_tool" '$1 == tool { print $3; exit }' "$_iut_desired")"
  # shellcheck disable=SC2016 # reason: awk script body must not be expanded by shell
  _iut_pin_source="$("$_iut_gawk_bin" -F'\t' -v tool="$_iut_tool" '$1 == tool { print $4; exit }' "$_iut_desired")"

  # Build the install spec.  "flake:<node>" pins take the revision from that
  # node in flake.lock; every other tool is pinned by the lockfile uv section
  # (version or VCS rev).  A tool installed from a flake rev carries no
  # comparable version, so it converges on presence rather than on the
  # version-aware reconciliation below.
  _iut_spec="$_iut_tool"
  _iut_reinstall=""
  case "$_iut_pin_source" in
  flake:*)
    if [ -z "$_iut_flake_lock" ]; then
      die -l uv "cannot resolve '$_iut_pin_source' for $_iut_tool: src/flake.lock not found"
    fi
    _iut_flake_node="${_iut_pin_source#flake:}"
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _iut_flake_ref="$("$_iut_jq_bin" -r --arg n "$_iut_flake_node" '
      .nodes[$n].locked
      | if . == null then ""
        elif .type == "github" then "git+https://github.com/\(.owner)/\(.repo)@\(.rev)"
        elif (.url // "") != "" then "git+\(.url)@\(.rev)"
        else "" end
    ' "$_iut_flake_lock")" || die -l uv "could not read src/flake.lock"
    if [ -z "$_iut_flake_ref" ]; then
      die -l uv "pin '$_iut_pin_source' for $_iut_tool does not resolve to a locked revision in src/flake.lock"
    fi
    _iut_spec="$_iut_tool @ $_iut_flake_ref"
    ;;
  "")
    if [ -n "$_iut_lockfile" ]; then
      # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the tool still installs.
      # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
      _iut_pin="$("$_iut_jq_bin" -r --arg p "$_iut_tool" '
        (.uv // {})[$p] as $e
        | if ($e | type) == "string" then "\($p)==\($e)"
          elif ($e | type) == "object" and (($e.source // "") != "") and (($e.rev // "") != "") then "\($p) @ git+\($e.source)@\($e.rev)"
          else "" end
      ' "$_iut_lockfile" 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile falls back to unpinned install -- safe, the tool still installs.
      if [ -n "$_iut_pin" ]; then
        _iut_spec="$_iut_pin"
        # Already-installed tools need --reinstall to converge to the pin.
        grep -qxF "$_iut_tool" "$_iut_installed" && _iut_reinstall="--reinstall"
      fi
    fi
    ;;
  *)
    die -l uv "unknown pin source '$_iut_pin_source' for $_iut_tool"
    ;;
  esac

  # Extras are a pip-style suffix.  A direct reference ("name @ git+...") is
  # only valid when the extras follow the distribution name, not the URL.
  if [ -n "$_iut_extras" ]; then
    case "$_iut_spec" in
    *" @ "*) _iut_spec="${_iut_tool}[$_iut_extras]${_iut_spec#"$_iut_tool"}" ;;
    *) _iut_spec="${_iut_spec}[$_iut_extras]" ;;
    esac
  fi

  if [ -n "$_iut_python" ]; then
    say -l uv "installing tool '$_iut_spec' with Python $_iut_python"
    # shellcheck disable=SC2086 # reason: _iut_reinstall is empty or a single flag, intentionally unquoted
    "$_iut_uv_bin" tool install --no-build --python "$_iut_python" $_iut_reinstall "$_iut_spec"
  else
    say -l uv "installing tool '$_iut_spec'"
    # shellcheck disable=SC2086 # reason: _iut_reinstall is empty or a single flag, intentionally unquoted
    "$_iut_uv_bin" tool install --no-build $_iut_reinstall "$_iut_spec"
  fi
done <"$_iut_to_install"

if [ ! -s "$_iut_to_install" ] && [ ! -s "$_iut_to_remove" ]; then
  say -l uv "all managed tools already converged — skipping"
fi

rm -f "$_iut_desired" "$_iut_desired_names" "$_iut_installed" "$_iut_installed_versions" "$_iut_to_remove" "$_iut_to_install"
