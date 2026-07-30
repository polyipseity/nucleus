# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "locked-dsc-validation" 12 "Locked DSC validation" run_12_locked_dsc_validation

run_12_locked_dsc_validation() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _lf_errors=0
  local _dsc_system_dir="src/hosts/Windows/system"
  local _lockfile="src/lockfiles/lockfile.json"

  # Generate locked DSC in-memory from ALL system DSC files + lockfile.
  local _dsc_par_tmpdir
  _dsc_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _lf_errors=$((_lf_errors + 1)); }
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "$_dsc_system_dir"/*.dsc.yml \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _safe="$(echo "$_f" | tr "/" "_")"
      yq eval -o=j "." "$_f" > "$_tmpdir/${_safe}.json" 2>/dev/null || rm -f "$_tmpdir/${_safe}.json"
    ' _ "$_dsc_par_tmpdir"

  local _locked_json
  if [ -n "$(find "$_dsc_par_tmpdir" -name '*.json' -print 2>/dev/null | head -1)" ]; then
    _locked_json=$(jq -s --argjson locked "$(jq -c '.winget // {}' "$_lockfile")" '
      { properties: { resources: (map(.properties.resources // []) | add) } } |
      .properties.resources |= [
        .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
          .settings.version = $locked[.settings.id]
        else
          .
        end
      ]
    ' "$_dsc_par_tmpdir"/*.json 2>/dev/null)
  else
    _locked_json="{}"
  fi
  rm -rf -- "$_dsc_par_tmpdir"

  # For each pinned resource, verify version matches lockfile.
  while IFS=$'\t' read -r _id _pinned_ver; do
    local _lf_ver
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      error "system DSC files: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      error "system DSC files: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(echo "$_locked_json" | jq -r '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | [.settings.id, .settings.version] | @tsv')

  # Check for lockfile entries missing version pins in generated output.
  while IFS=$'\t' read -r _id _lf_ver; do
    local _pinned
    _pinned=$(echo "$_locked_json" | jq -r --arg id "$_id" '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.id == $id) | .settings.version // ""')
    if [ -z "$_pinned" ]; then
      error "$_id ($_lf_ver) is in lockfile but missing version pin after generation"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(jq -r '.winget // {} | to_entries[] | [.key, .value] | @tsv' "$_lockfile")

  if [ "$_lf_errors" -gt 0 ]; then
    error "locked DSC validation failed with $_lf_errors error(s)"
    return 1
  fi
  say "locked DSC validation passed"
  return 0
}
