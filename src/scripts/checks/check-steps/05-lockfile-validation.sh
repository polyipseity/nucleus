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
      skip_step "$(step_number)" "Lockfile validation" "no lockfile files to check"
      return 2
    fi
  fi

  # --- Overlap check ---
  local _lf_overlap_issues=0
  if [ ! -f "$_lfpath" ]; then
    error "lockfile.json not found at $_lfpath"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  else
    local _lf_overlap_exceptions='["astral-sh.ty"]'
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
