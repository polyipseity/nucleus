# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "lockfile-validation" 11 "Lockfile validation" run_11_lockfile_validation

run_11_lockfile_validation() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _lf_errors=0
  local _lf_al_errors=0
  local _lf_section_errors=0
  local _lfpath="src/lockfiles/lockfile.json"
  local _lf_al_path="src/lockfiles/lifecycle-allowlist.json"

  # --- Overlap check ---
  local _lf_overlap_issues=0
  if [ ! -f "$_lfpath" ]; then
    error "lockfile.json not found at $_lfpath"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  else
    local _lf_overlap_exceptions='["astral-sh.ty"]'
    local _lf_overlaps
    _lf_overlaps=$(jq -r --argjson exceptions "$_lf_overlap_exceptions" '
      [to_entries[] | select(.key != "ollama" and (.value | type == "object")) | .key as $s | (.value | keys)[] | {s: $s, p: .}]
      | group_by(.p)
      | map(select(length > 1))
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

  # --- Section validation ---
  if [ -f "$_lfpath" ]; then
    _lf_section_errors=0

    _check_section_nonempty() {
      local _section="$1"
      if ! jq -e ".[\"$_section\"] | type == \"object\" and length > 0" "$_lfpath" >/dev/null 2>&1; then
        error "$_section: empty or missing section"
        _lf_section_errors=$((_lf_section_errors + 1))
        return
      fi
      local _placeholders
      _placeholders=$(jq -r ".[\"$_section\"] | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "$_section has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_section_errors=$((_lf_section_errors + 1))
      fi
    }

    for _section in scoop cargo-binstall bun uv rustup pwsh; do
      _check_section_nonempty "$_section"
    done

    # winget: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.winget | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      error "winget: missing or invalid section"
      _lf_section_errors=$((_lf_section_errors + 1))
    elif jq '.winget | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "winget: empty section (not yet populated)"
    else
      local _placeholders
      _placeholders=$(jq -r '.winget | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "winget has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_section_errors=$((_lf_section_errors + 1))
      fi
    fi

    # homebrew: must be non-empty
    if ! jq -e '.homebrew | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      error "homebrew: empty or missing section"
      _lf_section_errors=$((_lf_section_errors + 1))
    fi

    # vscode: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.vscode | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      error "vscode: missing or invalid section"
      _lf_section_errors=$((_lf_section_errors + 1))
    elif jq '.vscode | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "vscode: empty section (not yet populated)"
    else
      local _placeholders
      _placeholders=$(jq -r '.vscode | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "vscode has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_section_errors=$((_lf_section_errors + 1))
      fi
    fi

    # ollama: must have at least one profile with models
    if ! jq -e '.ollama | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      error "ollama: empty or missing section"
      _lf_section_errors=$((_lf_section_errors + 1))
    else
      while IFS=$'\t' read -r _profile _idx _name _tag; do
        if [ -z "$_name" ] || [ -z "$_tag" ]; then
          error "ollama.${_profile}[${_idx}]: missing name or tag"
          _lf_section_errors=$((_lf_section_errors + 1))
        fi
      done < <(jq -r '
        .ollama | to_entries[] | .key as $profile |
        (.value // []) | to_entries[] |
        [$profile, (.key | tostring), (.value.name // ""), (.value.tag // "")] |
        @tsv' "$_lfpath")
    fi

    if [ "$_lf_section_errors" -gt 0 ]; then
      error "lockfile.json validation failed with $_lf_section_errors error(s)"
      _lf_errors=$((_lf_errors + 1))
    else
      say "lockfile.json validation passed"
    fi
  else
    error "lockfile.json not found -- skipping section validation"
    _lf_errors=$((_lf_errors + 1))
  fi

  [ "$_lf_errors" -eq 0 ]
}
