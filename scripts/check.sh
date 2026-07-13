#!/usr/bin/env bash
# Fast pre-commit checks only. Heavy lint (ShellCheck, PSScriptAnalyzer)
# lives in test.sh.
#
# Runs repository checks in sequence:
#   1. Dead Nix code detection (deadnix)
#   2. Nix flake evaluation
#   3. Nix formatting check (nixfmt --verify)
#   4. PowerShell syntax validation (parser only, no PSScriptAnalyzer)
#   5. Packer template validation
#   6. Shell script validation tests
#   7. CWD-independence tests
#   8. Nix search path tests
#   9. Port utility function tests
#  10. Lockfile validation
#  11. Service registry validation
#  12. Locked DSC validation
#  13. Package manager usage enforcement
#  14. Stale Nix build artifact check
#  15. Online determinism checks (--verify mode only)
#  16. Undocumented error suppression check
#
# With arguments, passes them through to individual checkers that support
# path filtering (check-pwsh.ps1, check-packer.sh, nixfmt) and skips
# whole-repo checks (deadnix, script validation, lockfile/locked DSC).
#
# Arguments:
#   --format      Format Nix files in-place (instead of just validating).
#   (paths)       Files to check; passes paths through to sub-checkers and
#                 skips whole-repo checks (deadnix, script validation).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, all checks run and failures accumulate (report-at-end).
# Use --fail-fast to exit immediately on the first failure.
set -uo pipefail

exit_code=0
FAIL_FAST=false

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

FORMAT_NIX=false
VERIFY=false

usage() {
  usage_std "check.sh" "[--format] [--fail-fast] [--verify] [path ...]" "Run all repository validation checks in sequence. With arguments, passes paths through to supporting checkers and skips whole-repo checks (deadnix, script validation). Use --format to enable in-place Nix formatting (instead of just --verify). Use --fail-fast to exit immediately on first failure (default: accumulate all failures). Use --verify to additionally run online determinism checks (requires network)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --format)
      FORMAT_NIX=true
      shift
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

HAS_ARGS=false
[ "$#" -gt 0 ] && HAS_ARGS=true

# When paths are provided, group them by extension so each sub-checker
# receives only the files it understands. This allows prek (or other
# pre-commit tools) to invoke the consolidated check with a combined
# files pattern matching multiple extensions.
SH_FILES=()
PS1_FILES=()
PKR_FILES=()
NIX_FILES=()
if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.sh)      SH_FILES+=("$_f") ;;
      *.ps1)     PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
      *.nix)     NIX_FILES+=("$_f") ;;
    esac
  done
fi

_step=0

# Dead Nix code detection
section "$((_step += 1))" "Dead Nix code"
if ! $HAS_ARGS; then
  if ! deadnix --fail src/; then
    exit_code=$?
  else
    say "no dead Nix code found."
  fi
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping deadnix (path-scoped mode)."
fi

# Nix flake evaluation
section "$((_step += 1))" "Nix flake evaluation"
if ! $HAS_ARGS; then
  sys=$(nix eval --impure --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
  if ! nix eval --impure "path:./src#packages.$sys" >/dev/null; then
    exit_code=$?
  else
    say "nix flake evaluation passed."
  fi
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping nix flake check (path-scoped mode)."
fi

# Nix formatting check
section "$((_step += 1))" "Nix formatting (nixfmt)"
require_command nixfmt
if [ "${#NIX_FILES[@]}" -gt 0 ]; then
  if $FORMAT_NIX; then
    if nixfmt -s "${NIX_FILES[@]}"; then
      say "nix formatting applied."
    else
      exit_code=$?
    fi
  else
    if nixfmt -s --verify "${NIX_FILES[@]}"; then
      say "nix formatting OK."
    else
      exit_code=$?
    fi
  fi
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
elif ! $HAS_ARGS; then
  say "skipping nixfmt (standalone mode — use \`nix run .#nixfmt\` to check all Nix files)."
else
  say "skipping nixfmt (no Nix files to check)."
fi

# PowerShell syntax validation (parser only, no PSScriptAnalyzer)
section "$((_step += 1))" "PowerShell syntax validation"
require_command pwsh
_ps_exit=0
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly "${PS1_FILES[@]}" || _ps_exit=$?
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly || _ps_exit=$?
fi
if [ $_ps_exit -ne 0 ]; then exit_code=$_ps_exit; fi
$FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code

# Packer template validation
section "$((_step += 1))" "Packer template validation"
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}" || exit_code=$?
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh || exit_code=$?
else
  say "skipping (no Packer templates to check)."
fi
$FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code

# Shell script validation tests
section "$((_step += 1))" "Shell script validation tests"
if ! $HAS_ARGS; then
  bash tests/scripts/script-validation-tests.sh || exit_code=$?
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping validation tests (path-scoped mode)."
fi

# CWD-independence tests
section "$((_step += 1))" "CWD-independence tests"
if ! $HAS_ARGS; then
  bash tests/scripts/cwd-independence-tests.sh || exit_code=$?
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping cwd-independence tests (path-scoped mode)."
fi

# Nix search path regression tests
section "$((_step += 1))" "Nix search path tests"
if ! $HAS_ARGS; then
  bash tests/scripts/nix-search-path-tests.sh || exit_code=$?
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping nix-search-path tests (path-scoped mode)."
fi

# Port utility function tests
section "$((_step += 1))" "Port utility function tests"
if ! $HAS_ARGS; then
  bash tests/scripts/lib-port-functions-tests.sh || exit_code=$?
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping port utility function tests (path-scoped mode)."
fi

# Lockfile validation
section "$((_step += 1))" "Lockfile validation"

# Consistency and overlap checks (always run, even in path-scoped mode):
#  1. lockfile.json must exist.
#  2. No package should appear in multiple package-manager sections.
#     (Ollama is excluded because it uses a nested structure unrelated to
#      package versions.)
_lfpath="src/lockfiles/lockfile.json"
_lf_overlap_issues=0
if [ ! -f "$_lfpath" ]; then
    warn "lockfile.json not found at $_lfpath"
  _lf_overlap_issues=$((_lf_overlap_issues + 1))
  # Do not exit early — the section below may still run useful checks if
  # HAS_ARGS is false; the error count will cause a non-zero exit later.
else
  # Known cross-section overlaps that are legitimate (same publisher.package ID
  # used for different products across package-manager sections).
  # Add new entries here with a brief justification comment.
  # astral-sh.ty: VS Code extension (vscode) vs CLI tool (winget) — different products
  _lf_overlap_exceptions='["astral-sh.ty"]'
  _lf_overlaps=$(jq -r --argjson exceptions "$_lf_overlap_exceptions" '
    [to_entries[] | select(.key != "ollama" and (.value | type == "object")) | .key as $s | (.value | keys)[] | {s: $s, p: .}]
    | group_by(.p)
    | map(select(length > 1))
    | .[][]
    | select(.p as $p | ($exceptions | index($p)) | not)
    | "ERROR: package \"\(.p)\" appears in both \(.s)"' "$_lfpath" 2>/dev/null)
  if [ -n "$_lf_overlaps" ]; then
    warn "$_lf_overlaps"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  fi
fi
if [ "$_lf_overlap_issues" -gt 0 ]; then
  warn "lockfile.json has $_lf_overlap_issues overlapping package(s) across sections"
  exit_code=1
  $FAIL_FAST && exit $exit_code
else
  say "lockfile.json consistency: no overlapping packages across sections"
fi

# Lifecycle script allowlist validation (always run):
#  - lifecycle-allowlist.json must exist and be a valid JSON object.
#  - Each entry must have a non-empty justification string.
#  - The allowlist starts empty — this provides the mechanism for future
#    per-package lifecycle script approval.
_lf_al_path="src/lockfiles/lifecycle-allowlist.json"
_lf_al_errors=0
if [ ! -f "$_lf_al_path" ]; then
  warn "lifecycle-allowlist.json not found at $_lf_al_path"
  _lf_al_errors=$((_lf_al_errors + 1))
else
  _al_is_obj=$(jq -e 'type == "object"' "$_lf_al_path" >/dev/null 2>&1 && echo true || echo false)
  if [ "$_al_is_obj" != "true" ]; then
    warn "lifecycle-allowlist.json must be a JSON object"
    _lf_al_errors=$((_lf_al_errors + 1))
  else
    # Validate each entry has a non-empty justification string.
    _al_invalid=$(jq -r '
      to_entries[] | select(.value | type != "string" or .value == "") |
      "WARNING: lifecycle-allowlist.json: \"\(.key)\" has empty or non-string justification"' "$_lf_al_path")
    if [ -n "$_al_invalid" ]; then
      warn "$_al_invalid"
      _lf_al_errors=$((_lf_al_errors + 1))
    fi
  fi
fi
if [ "$_lf_al_errors" -gt 0 ]; then
  warn "lifecycle-allowlist.json validation failed with $_lf_al_errors error(s)"
  exit_code=1
  $FAIL_FAST && exit $exit_code
fi
say "lifecycle-allowlist.json: valid (entry count: $(jq 'length' "$_lf_al_path" 2>/dev/null || echo 0))"

if ! $HAS_ARGS; then
  _lf_errors=0

  # Helper: check a section is non-null, non-empty, and has no placeholder values.
  _check_section_nonempty() {
    _section="$1"
    _lfpath="src/lockfiles/lockfile.json"
    if ! jq -e ".[\"$_section\"] | type == \"object\" and length > 0" "$_lfpath" >/dev/null 2>&1; then
      warn "$_section: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
      return
    fi
    # Check for placeholder values
    _placeholders=$(jq -r ".[\"$_section\"] | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      warn "$_section has placeholder versions for:"
      warn "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  }

  # Check sections that must be non-empty
  for _section in scoop cargo-binstall bun uv rustup pwsh; do
    _check_section_nonempty "$_section"
  done

  # winget: must be non-null; warn if empty, validate non-placeholder if non-empty
  if ! jq -e '.winget | type == "object"' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    warn "winget: missing or invalid section"
    _lf_errors=$((_lf_errors + 1))
  elif jq '.winget | length == 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    say "winget: empty section (not yet populated)"
  else
    _placeholders=$(jq -r '.winget | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' src/lockfiles/lockfile.json 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      warn "winget has placeholder versions for:"
      warn "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  fi
  # homebrew: must be non-empty
  if ! jq -e '.homebrew | type == "object" and length > 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    warn "homebrew: empty or missing section"
    _lf_errors=$((_lf_errors + 1))
  fi
  # vscode: must be non-null; warn if empty, validate non-placeholder if non-empty
  if ! jq -e '.vscode | type == "object"' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    warn "vscode: missing or invalid section"
    _lf_errors=$((_lf_errors + 1))
  elif jq '.vscode | length == 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    say "vscode: empty section (not yet populated)"
  else
    _placeholders=$(jq -r '.vscode | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' src/lockfiles/lockfile.json 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      warn "vscode has placeholder versions for:"
      warn "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  fi

  # ollama: must have at least one profile with models
  if ! jq -e '.ollama | type == "object" and length > 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    warn "ollama: empty or missing section"
    _lf_errors=$((_lf_errors + 1))
  else
    while IFS=$'\t' read -r _profile _idx _name _tag; do
      if [ -z "$_name" ] || [ -z "$_tag" ]; then
        warn "ollama.${_profile}[${_idx}]: missing name or tag"
        _lf_errors=$((_lf_errors + 1))
      fi
    done < <(jq -r '
      .ollama | to_entries[] | .key as $profile |
      (.value // []) | to_entries[] |
      [$profile, (.key | tostring), (.value.name // ""), (.value.tag // "")] |
      @tsv' src/lockfiles/lockfile.json)
  fi

  if [ "$_lf_errors" -gt 0 ]; then
    warn "lockfile.json validation failed with $_lf_errors error(s)"
    exit_code=1
    $FAIL_FAST && exit $exit_code
  fi
  say "lockfile.json validation passed"
else
  say "skipping lockfile validation (path-scoped mode)."
fi

# Service registry validation
section "$((_step += 1))" "Service registry validation"
if ! $HAS_ARGS; then
  _svc_json="src/modules/services.json"
  _svc_errors=0

  if [ ! -f "$_svc_json" ]; then
    warn "services.json not found at $_svc_json"
    _svc_errors=$((_svc_errors + 1))
  else
    # Check each entry has displayName and platforms
    while IFS=$'\t' read -r _name _has_display _has_platforms _platform_count; do
      if [ "$_has_display" != "true" ]; then
        warn "services.json: '$_name' missing displayName"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_has_platforms" != "true" ]; then
        warn "services.json: '$_name' missing platforms"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_platform_count" -lt 1 ]; then
        warn "services.json: '$_name' has no platform entries"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] |
      [
        .key,
        (.value | has("displayName") and (.value.displayName | type == "string") and (.value.displayName | length > 0)) | tostring,
        (.value | has("platforms") and (.value.platforms | type == "object")) | tostring,
        (.value.platforms | if type == "object" then (keys | length) else 0 end) | tostring
      ] | @tsv' "$_svc_json")

    # Validate each platform entry has valid type and required fields
    while IFS=$'\t' read -r _name _platform _type _has_required; do
      case "$_type" in
        launchctl|systemctl|native|schtask|omitted) ;;
        *)
          warn "services.json: '$_name' platform '$_platform' has invalid type '$_type'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      if [ "$_has_required" != "true" ]; then
        warn "services.json: '$_name' platform '$_platform' missing required fields for type '$_type'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] |
      .key as $name |
      (.value.platforms // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (
          if .value.type == "launchctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "systemctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "native" then (.value.service | type == "string" and length > 0)
          elif .value.type == "schtask" then (.value.taskPath | type == "string" and length > 0)
          elif .value.type == "omitted" then (.value.justification | type == "string" and length > 0)
          else false
          end
        ) | tostring
      ] | @tsv' "$_svc_json")
  fi

  if [ "$_svc_errors" -gt 0 ]; then
    warn "services.json validation failed with $_svc_errors error(s)"
    exit_code=1
    $FAIL_FAST && exit $exit_code
  fi
  say "services.json validation passed"

  # Validate user-scoped platform entries have justification.
  # User-scoped means domain=user (macOS launchctl) or scope=user (Linux systemctl).
  while IFS=$'\t' read -r _name _platform _domain_scope _value; do
    if [ "$_domain_scope" = "user" ] && { [ "$_value" = "null" ] || [ -z "$_value" ]; }; then
      warn "services.json: '$_name' platform '$_platform' is user-scoped but missing justification"
      _svc_errors=$((_svc_errors + 1))
    fi
  done < <(jq -r '
    to_entries[] |
    .key as $name |
    (.value.platforms // {}) | to_entries[] |
    [
      $name,
      .key,
      (.value.domain // .value.scope // ""),
      (.value.justification | tostring)
    ] | @tsv' "$_svc_json")

  # Validate that service names in users.json services blocks exist in services.json.
  _users_json="src/modules/users.json"
  if [ -f "$_users_json" ]; then
    _svc_names=$(jq -r 'to_entries[].key' "$_svc_json")
    while IFS=$'\t' read -r _username _svc_name _has_enable; do
      if ! echo "$_svc_names" | grep -qxF "$_svc_name"; then
        warn "$_users_json: user '$_username' references unknown service '$_svc_name'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] |
      .key as $user |
      (.value.services // {}) | to_entries[] |
      select(.value.enable != null) |
      [$user, .key, "true"] | @tsv' "$_users_json")
  fi

  # Windows users.json
  _win_users_json="src/hosts/Windows/users.json"
  if [ -f "$_win_users_json" ]; then
    while IFS=$'\t' read -r _username _svc_name _has_enable; do
      if ! echo "$_svc_names" | grep -qxF "$_svc_name"; then
        warn "$_win_users_json: user '$_username' references unknown service '$_svc_name'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      .users // {} | to_entries[] |
      .key as $user |
      (.value.services // {}) | to_entries[] |
      select(.value.enable != null) |
      [$user, .key, "true"] | @tsv' "$_win_users_json")
  fi
else
  say "skipping service registry validation (path-scoped mode)."
fi

# Locked DSC validation
section "$((_step += 1))" "Locked DSC validation"
if ! $HAS_ARGS; then
  _dsc_system_dir="src/hosts/Windows/system"
  _lockfile="src/lockfiles/lockfile.json"
  _lf_errors=0

  # Generate locked DSC in-memory from ALL system DSC files + lockfile.
  # This mirrors check.ps1's behavior — validates version pins across the
  # full system configuration, not just packages.dsc.yml.
  _locked_json=$(yq eval -o=j '.' "$_dsc_system_dir"/*.dsc.yml 2>/dev/null | jq -s --argjson locked "$(jq -c '.winget // {}' "$_lockfile")" '
    { properties: { resources: (map(.properties.resources // []) | add) } } |
    .properties.resources |= [
      .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
        .settings.version = $locked[.settings.id]
      else
        .
      end
    ]
  ')

  # For each pinned resource, verify version matches lockfile.
  while IFS=$'\t' read -r _id _pinned_ver; do
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      warn "system DSC files: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      warn "system DSC files: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(echo "$_locked_json" | jq -r '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | [.settings.id, .settings.version] | @tsv')

  # Check for lockfile entries missing version pins in generated output.
  while IFS=$'\t' read -r _id _lf_ver; do
    _pinned=$(echo "$_locked_json" | jq -r --arg id "$_id" '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.id == $id) | .settings.version // ""')
    if [ -z "$_pinned" ]; then
      warn "$_id ($_lf_ver) is in lockfile but missing version pin after generation"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(jq -r '.winget // {} | to_entries[] | [.key, .value] | @tsv' "$_lockfile")

  if [ "$_lf_errors" -gt 0 ]; then
    warn "locked DSC validation failed with $_lf_errors error(s)"
    exit_code=1
    $FAIL_FAST && exit $exit_code
  fi
  say "locked DSC validation passed"
else
  say "skipping locked DSC validation (path-scoped mode)."
fi

# Package manager usage enforcement
section "$((_step += 1))" "Package manager usage enforcement"
# Ban bare `pip install` and `npm install` — these bypass the lockfile and
# produce non-reproducible environments.  `uv pip install` is allowed (uv
# respects the lockfile).  Exclude self-references and help-text mentions.
if ! $HAS_ARGS; then
  _violations=0
  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
       -E '(^|[^a-z])pip install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
       | grep -v 'uv pip install' \
       | grep . >/dev/null 2>&1; then
    warn "bare pip install detected (use uv pip install instead)"
    _violations=$((_violations + 1))
  fi
  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
       -E '(^|[^a-z])npm install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
       | grep . >/dev/null 2>&1; then
    warn "bare npm install detected (use bun or nix instead)"
    _violations=$((_violations + 1))
  fi
  if [ "$_violations" -gt 0 ]; then
    exit_code=1
    $FAIL_FAST && exit $exit_code
  fi
  say "no package manager violations found."
else
  say "skipping (path-scoped mode)."
fi

# Stale Nix build artifact check
section "$((_step += 1))" "Stale Nix build artifact check"
if ! $HAS_ARGS; then
  _cnba_output="$("$SCRIPT_DIR/cleanup-nix.sh" --dry-run 2>&1)"
  if echo "$_cnba_output" | grep -q "would remove stale Nix build symlink"; then
    warn "stale Nix build artifacts found:"
    echo "$_cnba_output" | while IFS= read -r _cnba_line; do
      warn "  $_cnba_line"
    done
    exit_code=1
  else
    say "no stale Nix build artifacts found."
  fi
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping (path-scoped mode)."
fi

# Online determinism checks (--verify mode only)
section "$((_step += 1))" "Online determinism checks (--verify)"
if $VERIFY; then
  bash "$SCRIPT_DIR/bump-lockfile.sh" --verify || exit_code=$?
  if [ $exit_code -eq 0 ]; then
    say "online determinism checks passed."
  fi
  $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping (use --verify to run online determinism checks)."
fi

# Undocumented error suppression check
section "$((_step += 1))" "Undocumented error suppression"
_undoc_supp_out="$(mktemp)" || { warn "failed to create temp file"; exit_code=1; $FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code; }

_check_undoc_supp() {
  local _grep_flags="$1" _pattern="$2" _label="$3"
  shift 3
  [ $# -eq 0 ] && return
  grep -Hrn $_grep_flags -- "$_pattern" "$@" 2>/dev/null | while IFS=: read -r _f _ln _rest; do
    # Skip comment-only lines (pattern in a comment, not code)
    [[ "$_rest" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with # undoc-supp: inline
    case "$_rest" in *'# undoc-supp:'*) continue ;; esac
    # Skip lines with # undoc-supp: on the immediately preceding line
    [ "$_ln" -gt 1 ] && sed -n "$((_ln - 1))p" "$_f" | grep -q '# undoc-supp:' && continue
    echo "$_f:$_ln ($_label)"
  done >> "$_undoc_supp_out"
}

if $HAS_ARGS; then
  # Path-scoped mode: check only provided files
  # undoc-supp: string argument specifying the suppression pattern for the check function, not a real || true operator.
  [ ${#SH_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '|| true' '|| true' "${SH_FILES[@]}"
  # undoc-supp: string argument specifying the suppression pattern for the check function, not a real || true operator.
  [ ${#NIX_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '|| true' '|| true' "${NIX_FILES[@]}"
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '2>$null' '2>$null' "${PS1_FILES[@]}"
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '-ErrorAction SilentlyContinue' '-ErrorAction SilentlyContinue' "${PS1_FILES[@]}"
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-E' 'catch[[:space:]]*\{[[:space:]]*\}' 'empty catch {}' "${PS1_FILES[@]}"
else
  # Full mode: find all relevant files
  # undoc-supp: string argument specifying the suppression pattern for the check function, not a real || true operator.
  _check_undoc_supp '-F' '|| true' '|| true' $(find . -path ./vendor -prune -o \( -name '*.nix' -print \) -o \( -name '*.sh' -print \))
  _check_undoc_supp '-F' '2>$null' '2>$null' $(find . -path ./vendor -prune -o -name '*.ps1' -print)
  _check_undoc_supp '-F' '-ErrorAction SilentlyContinue' '-ErrorAction SilentlyContinue' $(find . -path ./vendor -prune -o -name '*.ps1' -print)
  _check_undoc_supp '-E' 'catch[[:space:]]*\{[[:space:]]*\}' 'empty catch {}' $(find . -path ./vendor -prune -o -name '*.ps1' -print)
fi

if [ -s "$_undoc_supp_out" ]; then
  warn "undocumented error suppressions found:"
  sort -u "$_undoc_supp_out" | while IFS= read -r _line; do
    warn "  $_line"
  done
  exit_code=1
else
  say "no undocumented error suppressions found."
fi
rm -f "$_undoc_supp_out"
$FAIL_FAST && [ $exit_code -ne 0 ] && exit $exit_code

if [ $exit_code -ne 0 ]; then
  warn "some checks failed with exit code $exit_code"
  exit $exit_code
fi
nuc_done
