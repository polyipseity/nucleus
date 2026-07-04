#!/usr/bin/env bash
# Fast pre-commit checks only. Heavy lint (ShellCheck, PSScriptAnalyzer)
# lives in test.sh.
#
# Runs repository checks in sequence:
#   1. Dead Nix code detection (deadnix)
#   2. Nix formatting check (nixfmt --verify)
#   3. PowerShell syntax validation (parser only, no PSScriptAnalyzer)
#   4. Packer template validation
#   5. Shell script validation tests
#   6. Lockfile validation
#   7. Service registry validation
#   8. Locked DSC validation
#   9. Package manager usage enforcement
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
set -euo pipefail

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
cd "$REPO_ROOT"

FORMAT_NIX=false

usage() {
  usage_std "check.sh" "[--format] [path ...]" "Run all repository validation checks in sequence. With arguments, passes paths through to supporting checkers and skips whole-repo checks (deadnix, script validation). Use --format to enable in-place Nix formatting (instead of just --verify)."
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
    -*)
      printf '%s\n' "error: unsupported argument '$1'" >&2
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
PS1_FILES=()
PKR_FILES=()
NIX_FILES=()
if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.ps1)     PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
      *.nix)     NIX_FILES+=("$_f") ;;
    esac
  done
fi

_step=0

# Dead Nix code detection
printf '\n=== [%s] Dead Nix code ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  deadnix --fail src/
  echo "No dead Nix code found."
else
  echo "Skipping deadnix (path-scoped mode)."
fi

# Nix flake evaluation
printf '\n=== [%s] Nix flake evaluation ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  sys=$(nix eval --impure --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
  nix eval --impure "path:./src#packages.$sys" >/dev/null
  echo "Nix flake evaluation passed."
else
  echo "Skipping nix flake check (path-scoped mode)."
fi

# Nix formatting check
printf '\n=== [%s] Nix formatting (nixfmt) ===\n' "$((_step += 1))"
require_command nixfmt
if [ "${#NIX_FILES[@]}" -gt 0 ]; then
  if $FORMAT_NIX; then
    nixfmt -s "${NIX_FILES[@]}"
    echo "Nix formatting applied."
  else
    nixfmt -s --verify "${NIX_FILES[@]}"
    echo "Nix formatting OK."
  fi
elif ! $HAS_ARGS; then
  echo "Skipping nixfmt (standalone mode — use \`nix run .#nixfmt\` to check all Nix files)."
else
  echo "Skipping nixfmt (no Nix files to check)."
fi

# PowerShell syntax validation (parser only, no PSScriptAnalyzer)
printf '\n=== [%s] PowerShell syntax validation ===\n' "$((_step += 1))"
require_command pwsh
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly "${PS1_FILES[@]}"
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly
else
  echo "Skipping (no PowerShell scripts to check)."
fi

# Packer template validation
printf '\n=== [%s] Packer template validation ===\n' "$((_step += 1))"
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh
else
  echo "Skipping (no Packer templates to check)."
fi

# Shell script validation tests
printf '\n=== [%s] Shell script validation tests ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  bash tests/scripts/script-validation-tests.sh
else
  echo "Skipping validation tests (path-scoped mode)."
fi

# CWD-independence tests
printf '\n=== [%s] CWD-independence tests ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  bash tests/scripts/cwd-independence-tests.sh
else
  echo "Skipping cwd-independence tests (path-scoped mode)."
fi

# Lockfile validation
printf '\n=== [%s] Lockfile validation ===\n' "$((_step += 1))"

# Consistency and overlap checks (always run, even in path-scoped mode):
#  1. lockfile.json must exist.
#  2. No package should appear in multiple package-manager sections.
#     (Ollama is excluded because it uses a nested structure unrelated to
#      package versions.)
_lfpath="src/lockfiles/lockfile.json"
_lf_overlap_issues=0
if [ ! -f "$_lfpath" ]; then
  echo "ERROR: lockfile.json not found at $_lfpath"
  _lf_overlap_issues=$((_lf_overlap_issues + 1))
  # Do not exit early — the section below may still run useful checks if
  # HAS_ARGS is false; the error count will cause a non-zero exit later.
else
  _lf_overlaps=$(jq -r '
    [to_entries[] | select(.key != "ollama" and (.value | type == "object")) | .key as $s | (.value | keys)[] | {s: $s, p: .}]
    | group_by(.p)
    | map(select(length > 1))
    | .[][]
    | "WARNING: package \"\(.p)\" appears in both \(.s)"' "$_lfpath" 2>/dev/null)
  if [ -n "$_lf_overlaps" ]; then
    echo "$_lf_overlaps"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  fi
fi
if [ "$_lf_overlap_issues" -gt 0 ]; then
  echo "lockfile.json consistency: $_lf_overlap_issues overlap issue(s) (warnings only)"
else
  echo "lockfile.json consistency: no overlapping packages across sections"
fi

if ! $HAS_ARGS; then
  _lf_errors=0

  # Helper: check a section is non-null, non-empty, and has no placeholder values.
  _check_section_nonempty() {
    _section="$1"
    _lfpath="src/lockfiles/lockfile.json"
    if ! jq -e ".[\"$_section\"] | type == \"object\" and length > 0" "$_lfpath" >/dev/null 2>&1; then
      echo "ERROR: $_section: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
      return
    fi
    # Check for placeholder values
    _placeholders=$(jq -r ".[\"$_section\"] | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      echo "ERROR: $_section has placeholder versions for:"
      echo "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  }

  # Check sections that must be non-empty
  for _section in scoop cargo-binstall bun uv rustup pwsh; do
    _check_section_nonempty "$_section"
  done

  # winget: must be non-null; warn if empty, validate non-placeholder if non-empty
  if ! jq -e '.winget | type == "object"' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "ERROR: winget: missing or invalid section"
    _lf_errors=$((_lf_errors + 1))
  elif jq '.winget | length == 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "WARNING: winget: empty section (not yet populated)"
  else
    _placeholders=$(jq -r '.winget | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' src/lockfiles/lockfile.json 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      echo "ERROR: winget has placeholder versions for:"
      echo "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  fi
  # homebrew: must be non-empty
  if ! jq -e '.homebrew | type == "object" and length > 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "ERROR: homebrew: empty or missing section"
    _lf_errors=$((_lf_errors + 1))
  fi
  # vscode: must be non-null; warn if empty, validate non-placeholder if non-empty
  if ! jq -e '.vscode | type == "object"' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "ERROR: vscode: missing or invalid section"
    _lf_errors=$((_lf_errors + 1))
  elif jq '.vscode | length == 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "WARNING: vscode: empty section (not yet populated)"
  else
    _placeholders=$(jq -r '.vscode | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' src/lockfiles/lockfile.json 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      echo "ERROR: vscode has placeholder versions for:"
      echo "  ${_placeholders//$'\n'/$'\n'  }"
      _lf_errors=$((_lf_errors + 1))
    fi
  fi

  # ollama: must have at least one profile with models
  if ! jq -e '.ollama | type == "object" and length > 0' src/lockfiles/lockfile.json >/dev/null 2>&1; then
    echo "ERROR: ollama: empty or missing section"
    _lf_errors=$((_lf_errors + 1))
  else
    while IFS=$'\t' read -r _profile _idx _name _tag; do
      if [ -z "$_name" ] || [ -z "$_tag" ]; then
        echo "ERROR: ollama.${_profile}[${_idx}]: missing name or tag"
        _lf_errors=$((_lf_errors + 1))
      fi
    done < <(jq -r '
      .ollama | to_entries[] | .key as $profile |
      (.value // []) | to_entries[] |
      [$profile, (.key | tostring), (.value.name // ""), (.value.tag // "")] |
      @tsv' src/lockfiles/lockfile.json)
  fi

  if [ "$_lf_errors" -gt 0 ]; then
    echo "ERROR: lockfile.json validation failed with $_lf_errors error(s)"
    exit 1
  fi
  echo "lockfile.json validation passed"
else
  echo "Skipping lockfile validation (path-scoped mode)."
fi

# Service registry validation
printf '\n=== [%s] Service registry validation ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  _svc_json="src/modules/services.json"
  _svc_errors=0

  if [ ! -f "$_svc_json" ]; then
    echo "ERROR: services.json not found at $_svc_json"
    _svc_errors=$((_svc_errors + 1))
  else
    # Check each entry has displayName and platforms
    while IFS=$'\t' read -r _name _has_display _has_platforms _platform_count; do
      if [ "$_has_display" != "true" ]; then
        echo "ERROR: services.json: '$_name' missing displayName"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_has_platforms" != "true" ]; then
        echo "ERROR: services.json: '$_name' missing platforms"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_platform_count" -lt 1 ]; then
        echo "ERROR: services.json: '$_name' has no platform entries"
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
        launchctl|systemctl|native|schtask) ;;
        *)
          echo "ERROR: services.json: '$_name' platform '$_platform' has invalid type '$_type'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      if [ "$_has_required" != "true" ]; then
        echo "ERROR: services.json: '$_name' platform '$_platform' missing required fields for type '$_type'"
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
          else false
          end
        ) | tostring
      ] | @tsv' "$_svc_json")
  fi

  if [ "$_svc_errors" -gt 0 ]; then
    echo "ERROR: services.json validation failed with $_svc_errors error(s)"
    exit 1
  fi
  echo "services.json validation passed"

  # Validate user-scoped platform entries have justification.
  # User-scoped means domain=user (macOS launchctl) or scope=user (Linux systemctl).
  while IFS=$'\t' read -r _name _platform _domain_scope _value; do
    if [ "$_domain_scope" = "user" ] && { [ "$_value" = "null" ] || [ -z "$_value" ]; }; then
      echo "ERROR: services.json: '$_name' platform '$_platform' is user-scoped but missing justification"
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
        echo "ERROR: $_users_json: user '$_username' references unknown service '$_svc_name'"
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
        echo "ERROR: $_win_users_json: user '$_username' references unknown service '$_svc_name'"
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
  echo "Skipping service registry validation (path-scoped mode)."
fi

# Locked DSC validation
printf '\n=== [%s] Locked DSC validation ===\n' "$((_step += 1))"
if ! $HAS_ARGS; then
  _dsc_system_packages="src/hosts/Windows/system/packages.dsc.yml"
  _lockfile="src/lockfiles/lockfile.json"
  _lf_errors=0

  # Generate locked DSC in-memory from system packages DSC + lockfile.
  _locked_json=$(jq -s --argjson locked "$(jq -c '.winget // {}' "$_lockfile")" '
    { properties: { resources: .[0].properties.resources } } |
    .properties.resources |= [
      .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
        .settings.version = $locked[.settings.id]
      else
        .
      end
    ]
  ' <(yq eval -o=j '.' "$_dsc_system_packages"))

  # For each pinned resource, verify version matches lockfile.
  while IFS=$'\t' read -r _id _pinned_ver; do
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      echo "ERROR: system DSC files: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      echo "ERROR: system DSC files: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(echo "$_locked_json" | jq -r '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | [.settings.id, .settings.version] | @tsv')

  # Check for lockfile entries missing version pins in generated output.
  while IFS=$'\t' read -r _id _lf_ver; do
    _pinned=$(echo "$_locked_json" | jq -r --arg id "$_id" '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.id == $id) | .settings.version // ""')
    if [ -z "$_pinned" ]; then
      echo "ERROR: $_id ($_lf_ver) is in lockfile but missing version pin after generation"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(jq -r '.winget // {} | to_entries[] | [.key, .value] | @tsv' "$_lockfile")

  if [ "$_lf_errors" -gt 0 ]; then
    echo "ERROR: locked DSC validation failed with $_lf_errors error(s)"
    exit 1
  fi
  echo "Locked DSC validation passed"
else
  echo "Skipping locked DSC validation (path-scoped mode)."
fi

# Package manager usage enforcement
printf '\n=== [%s] Package manager usage enforcement ===\n' "$((_step += 1))"
# Ban bare `pip install` and `npm install` — these bypass the lockfile and
# produce non-reproducible environments.  `uv pip install` is allowed (uv
# respects the lockfile).  Exclude self-references and help-text mentions.
if ! $HAS_ARGS; then
  _violations=0
  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' \
       -E '(^|[^a-z])pip install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
       | grep -v 'uv pip install' \
       | grep . >/dev/null 2>&1; then
    echo "ERROR: bare pip install detected (use uv pip install instead)"
    _violations=$((_violations + 1))
  fi
  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' \
       -E '(^|[^a-z])npm install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
       | grep . >/dev/null 2>&1; then
    echo "ERROR: bare npm install detected (use bun or nix instead)"
    _violations=$((_violations + 1))
  fi
  if [ "$_violations" -gt 0 ]; then
    exit 1
  fi
  echo "No package manager violations found."
else
  echo "Skipping (path-scoped mode)."
fi

printf '\nAll checks passed.\n'
