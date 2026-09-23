# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "lockfile-validation" "Lockfile validation" run_lockfile_validation

run_lockfile_validation() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _lf_errors=0
  local _lf_al_errors=0
  local _lf_section_errors=0
  local _lfpath="src/lockfiles/lockfile.json"
  local _lf_al_path="src/lockfiles/lifecycle-allowlist.json"

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if $_has_args; then
    local _f _has_lf_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in */lockfile.json | */lifecycle-allowlist.json)
        _has_lf_files=1
        break
        ;;
      esac
    done
    if [ "$_has_lf_files" -eq 0 ]; then
      say "0 lockfile files in scope — nothing to validate."
      return 0
    fi
  fi

  # --- Overlap check ---
  local _lf_overlap_issues=0
  if [ ! -f "$_lfpath" ]; then
    error "lockfile.json not found at $_lfpath"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  else
    local _lf_overlap_exceptions='["astral-sh.ty","Windows"]' # ref: allow-and-deny-lists.instructions.md#D1
    local _lf_overlaps
    # Note: cursor and vscode are both VS Code–based editors; identical
    # extension IDs across these two sections are expected and excluded.
    _lf_overlaps=$(jq -r --argjson exceptions "$_lf_overlap_exceptions" '
      [
        (to_entries[] | select(.key != "suggestions" and .key != "ollama" and (.value | type == "object")) | .key as $s | (.value | keys)[] | {s: $s, p: .}),
        (.suggestions.homebrew.masApps // {} | keys[] | {s: "suggestions.homebrew.masApps", p: .}),
        (.suggestions.cursor // {} | keys[] | {s: "suggestions.cursor", p: .}),
        (.suggestions.vscode // {} | keys[] | {s: "suggestions.vscode", p: .})
      ]
      | group_by(.p)
      | map(select(length > 1))
      | map(select(map(.s) | map(select(. != "suggestions.cursor" and . != "suggestions.vscode" and . != "cursor" and . != "vscode")) | length > 0))
      | .[][]
      | select(.p as $p | ($exceptions | index($p)) | not)
      | "ERROR: package \"\(.p)\" appears in both \(.s)"' "$_lfpath" 2>/dev/null)
    if [ -n "$_lf_overlaps" ]; then
      error "$_lf_overlaps"
      _lf_overlap_issues=$((_lf_overlap_issues + 1))
    fi
  fi
  if [ "$_lf_overlap_issues" -gt 0 ]; then
    error "lockfile.json has $_lf_overlap_issues overlapping package(s) across sections"
    _lf_errors=$((_lf_errors + 1))
  else
    say "lockfile.json consistency: no overlapping packages across sections"
  fi

  # --- Lifecycle allowlist validation ---
  if [ ! -f "$_lf_al_path" ]; then
    error "lifecycle-allowlist.json not found at $_lf_al_path"
    _lf_al_errors=$((_lf_al_errors + 1))
  else
    local _al_is_obj
    _al_is_obj=$(jq -e 'type == "object"' "$_lf_al_path" >/dev/null 2>&1 && echo true || echo false)
    if [ "$_al_is_obj" != "true" ]; then
      error "lifecycle-allowlist.json must be a JSON object"
      _lf_al_errors=$((_lf_al_errors + 1))
    else
      local _al_invalid
      _al_invalid=$(jq -r '
        to_entries[] | select((.value | type) != "string" or .value == "") |
        "WARNING: lifecycle-allowlist.json: \"\(.key)\" has empty or non-string justification"' "$_lf_al_path")
      if [ -n "$_al_invalid" ]; then
        error "$_al_invalid"
        _lf_al_errors=$((_lf_al_errors + 1))
      fi
    fi
  fi
  if [ "$_lf_al_errors" -gt 0 ]; then
    error "lifecycle-allowlist.json validation failed with $_lf_al_errors error(s)"
    _lf_errors=$((_lf_errors + 1))
  else
    local _lf_al_count
    _lf_al_count=$(jq 'length' "$_lf_al_path" 2>/dev/null || echo 0)
    say "lifecycle-allowlist.json: valid (entry count: $_lf_al_count)"
  fi

  # Section validation (non-empty, no placeholders) is enforced by
  # lockfile.schema.json via step 07 (schema-validation). This step
  # only handles cross-section overlap and lifecycle-allowlist checks.

  say "lockfile.json validation passed"
  [ "$_lf_errors" -eq 0 ]
}

# run_online_determinism — Verify lockfile freshness against registries (requires network).
run_online_determinism() {
  local -n ctx="$1"
  local _repo_root="${ctx[REPO_ROOT]}"
  shift
  cd "$_repo_root" || return 1

  if bash "$_repo_root/scripts/update.sh" lockfile --verify; then
    say "online determinism checks passed."
    return 0
  else
    return 1
  fi
}

# run_locked_dsc_validation — Verify DSC package versions match lockfile pins.
run_locked_dsc_validation() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _lf_errors=0
  local _dsc_system_dir="src/hosts/Windows/system"
  local _lockfile="src/lockfiles/lockfile.json"

  local _dsc_par_tmpdir
  _dsc_par_tmpdir=$(mktemp -d) || {
    error "failed to create temp dir"
    _lf_errors=$((_lf_errors + 1))
  }
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "$_dsc_system_dir"/*.dsc.yml |
    xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
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
