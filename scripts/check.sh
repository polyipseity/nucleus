#!/usr/bin/env bash
# check.sh — Consolidated repository validation script.
#
# Runs all repository checks in sequence:
#   1. Dead Nix code detection (deadnix)
#   2. Shell script linting (shellcheck)
#   3. PowerShell syntax validation
#   4. Packer template validation
#   5. Shell script validation tests
#   6. Lockfile validation
#   7. Locked DSC validation
#   8. Package manager usage enforcement
#
# With arguments, passes them through to individual checkers that support
# path filtering (check-sh.sh, check-pwsh.ps1, check-packer.sh) and skips
# whole-repo checks (deadnix, script validation, lockfile/locked DSC).
#
# Arguments:
#   (none)        No flags accepted; paths may be provided as positional arguments.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT=$(resolve_nucleus_root)
cd "$REPO_ROOT"

usage() {
  usage_std "check.sh" "[path ...]" "Run all repository validation checks in sequence. With arguments, passes paths through to supporting checkers and skips whole-repo checks (deadnix, script validation)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
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
  shift
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
if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.sh)      SH_FILES+=("$_f") ;;
      *.ps1)     PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
    esac
  done
fi


# ---------------------------------------------------------------------------
# 1. Dead Nix code detection
# ---------------------------------------------------------------------------
printf '\n=== [1/7] Dead Nix code ===\n'
if ! $HAS_ARGS; then
  deadnix --fail src/
  echo "No dead Nix code found."
else
  echo "Skipping deadnix (path-scoped mode)."
fi

# ---------------------------------------------------------------------------
# 2. Shell script linting (shellcheck)
# ---------------------------------------------------------------------------
printf '\n=== [2/7] Shell script linting ===\n'
if [ "${#SH_FILES[@]}" -gt 0 ]; then
  bash scripts/check-sh.sh "${SH_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-sh.sh
else
  echo "Skipping (no shell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 3. PowerShell syntax validation
# ---------------------------------------------------------------------------
printf '\n=== [3/7] PowerShell syntax validation ===\n'
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 "${PS1_FILES[@]}"
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1
else
  echo "Skipping (no PowerShell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 4. Packer template validation
# ---------------------------------------------------------------------------
printf '\n=== [4/7] Packer template validation ===\n'
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh
else
  echo "Skipping (no Packer templates to check)."
fi

# ---------------------------------------------------------------------------
# 5. Shell script validation tests
# ---------------------------------------------------------------------------
printf '\n=== [5/7] Shell script validation tests ===\n'
if ! $HAS_ARGS; then
  bash tests/scripts/script-validation-tests.sh
else
  echo "Skipping validation tests (path-scoped mode)."
fi

# ---------------------------------------------------------------------------
# 6. Lockfile validation
# ---------------------------------------------------------------------------
printf '\n=== [6/7] Lockfile validation ===\n'
if ! $HAS_ARGS; then
  _lf_errors=0

  # Helper: check a section is non-null, non-empty, and has no placeholder values.
  _check_section_nonempty() {
    _section="$1"
    _lfpath="src/lockfiles/lockfile.json"
    if ! jq -e ".$_section | type == \"object\" and length > 0" "$_lfpath" >/dev/null 2>&1; then
      echo "ERROR: $_section: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
      return
    fi
    # Check for placeholder values
    _placeholders=$(jq -r ".$_section | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
    if [ -n "$_placeholders" ]; then
      echo "ERROR: $_section has placeholder versions for:"
      echo "$_placeholders" | sed 's/^/  /'
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
      echo "$_placeholders" | sed 's/^/  /'
      _lf_errors=$((_lf_errors + 1))
    fi
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
      echo "$_placeholders" | sed 's/^/  /'
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

# ---------------------------------------------------------------------------
# 7. Locked DSC validation
# ---------------------------------------------------------------------------
printf '\n=== [7/8] Locked DSC validation ===\n'
if ! $HAS_ARGS; then
  _dsc_locked="src/hosts/Windows/system-locked.dsc.yml"
  _lockfile="src/lockfiles/lockfile.json"

  if [ ! -f "$_dsc_locked" ]; then
    echo "ERROR: $_dsc_locked not found — run generate-winget-locked-dsc.sh first"
    exit 1
  fi

  _lf_errors=0

  # For each winget Package resource in the locked DSC, verify the version
  # matches the lockfile entry (if one exists).
  while IFS=$'\t' read -r _id _pinned_ver; do
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      echo "ERROR: $_dsc_locked: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      echo "ERROR: $_dsc_locked: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(yq eval -o=j '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | {id: .settings.id, version: .settings.version}' "$_dsc_locked" | jq -r '[.id, .version] | @tsv')

  # Check for winget packages in the lockfile that are NOT pinned in the locked DSC
  while IFS=$'\t' read -r _id _lf_ver; do
    _dsc_ver=$(yq eval ".properties.resources[] | select(.resource == \"Microsoft.WinGet.Client/Package\" and .settings.source == \"winget\" and .settings.id == \"$_id\") | .settings.version // \"\"" "$_dsc_locked")
    if [ -z "$_dsc_ver" ]; then
      echo "ERROR: $_dsc_locked: $_id ($_lf_ver) is in lockfile but missing version pin in locked DSC"
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

# ---------------------------------------------------------------------------
# 8. Package manager usage enforcement
# ---------------------------------------------------------------------------
printf '\n=== [8/8] Package manager usage enforcement ===\n'
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
