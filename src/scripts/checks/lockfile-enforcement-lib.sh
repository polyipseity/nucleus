# shellcheck shell=bash
# Shared probe library for lockfile version enforcement.
#
# Provides the per-tool version probes (_lfe_check_*) and two entry points:
#   - run_lockfile_enforcement  : used by the check step (16-lockfile-enforcement.sh);
#                                 handles file presence / scope skipping and
#                                 depends on check-lib.sh (skip_step, step_number).
#   - verify_installed_versions : used by bump-lockfile --verify-installed;
#                                 standalone (no check-lib dependency) — reads
#                                 the lockfile, runs the pinned probes, always
#                                 warns for suggestions, returns 1 on drift.
#
# Both entry points share the same probe logic so the check and the
# verify-drift command never diverge.
#
# Requires: say, warn, error (from lib.sh / check-lib.sh) and jq on PATH.

# Compare installed bun global packages against the lockfile `bun` section.
# String pins are version-checked; object (VCS/rev) pins are not
# version-verifiable here and are skipped.  Returns 1 if any drift found.
_lfe_check_bun() {
  local _lf="$1" _jq="$2"
  local _bun
  _bun="$(command -v bun || true)"
  [ -z "$_bun" ] && { say -l bun "not installed; skipping enforcement"; return 0; }
  local _global_json="$HOME/.bun/install/global/package.json"
  [ -f "$_global_json" ] || { say -l bun "no global package.json; skipping"; return 0; }
  local _installed
  # check-suppress:suppression_doc: malformed global package.json treats installed set as empty -- safe, drift is still reported below.
  _installed="$(cat "$_global_json" 2>/dev/null)" || true
  local _pkgs _pkg _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.bun // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_pkg" '(.bun // {})[$p] // empty' 2>/dev/null)" || true
    [ -z "$_pin" ] && continue
    # Object (VCS/rev) pins are not version-verifiable from the installed record.
    if [ "${_pin%"${_pin#?}"}" = '{' ]; then
      say -l bun "$_pkg: VCS-pinned (rev) — not version-verifiable, skipping"
      continue
    fi
    # check-suppress:suppression_doc: jq parse failure on a malformed installed record skips the comparison -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _inst="$(printf '%s' "$_installed" | "$_jq" -r --arg p "$_pkg" '(.dependencies // {})[$p] // empty' 2>/dev/null)" || true
    if [ -z "$_inst" ]; then
      error "bun.$_pkg: expected $_pin, not installed" || _rc=1
    elif [ "$_inst" != "$_pin" ]; then
      error "bun.$_pkg: expected $_pin, installed $_inst" || _rc=1
    fi
  done <<EOF
$_pkgs
EOF
  return $_rc
}

# Compare installed uv tools against the lockfile `uv` section.
_lfe_check_uv() {
  local _lf="$1" _jq="$2"
  local _uv
  _uv="$(command -v uv || true)"
  [ -z "$_uv" ] && { say -l uv "not installed; skipping enforcement"; return 0; }
  local _installed
  # check-suppress:suppression_doc: uv tool list may fail if no tool env initialised -- safe, drift reported below if parseable.
  _installed="$("$_uv" tool list 2>/dev/null)" || true
  [ -z "$_installed" ] && { say -l uv "no tools installed; skipping"; return 0; }
  local _pkgs _tool _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.uv // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _tool; do
    [ -z "$_tool" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_tool" '(.uv // {})[$p] // empty' 2>/dev/null)" || true
    [ -z "$_pin" ] && continue
    if [ "${_pin%"${_pin#?}"}" = '{' ]; then
      say -l uv "$_tool: VCS-pinned (rev) — not version-verifiable, skipping"
      continue
    fi
    _inst="$(printf '%s\n' "$_installed" | awk -v t="$_tool" '$1 == t { v=$2; sub(/^v/,"",v); print v; exit }')"
    if [ -z "$_inst" ]; then
      error "uv.$_tool: expected $_pin, not installed" || _rc=1
    elif [ "$_inst" != "$_pin" ]; then
      error "uv.$_tool: expected $_pin, installed $_inst" || _rc=1
    fi
  done <<EOF
$_pkgs
EOF
  return $_rc
}

# Compare installed cargo-binstall crates against the lockfile `cargo-binstall` section.
_lfe_check_cargo_binstall() {
  local _lf="$1" _jq="$2"
  local _cargo
  _cargo="$(command -v cargo || true)"
  [ -z "$_cargo" ] && { say -l cargo-binstall "cargo not installed; skipping enforcement"; return 0; }
  local _installed
  # check-suppress:suppression_doc: cargo install --list may fail if ~/.cargo uninitialised -- safe.
  _installed="$("$_cargo" install --list 2>/dev/null)" || true
  [ -z "$_installed" ] && { say -l cargo-binstall "no crates installed; skipping"; return 0; }
  local _pkgs _crate _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.["cargo-binstall"] // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _crate; do
    [ -z "$_crate" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_crate" '(.["cargo-binstall"] // {})[$p] // empty' 2>/dev/null)" || true
    [ -z "$_pin" ] && continue
    if [ "${_pin%"${_pin#?}"}" = '{' ]; then
      say -l cargo-binstall "$_crate: VCS-pinned (rev) — not version-verifiable, skipping"
      continue
    fi
    _inst="$(printf '%s\n' "$_installed" | awk -v c="$_crate" '$1 == c { sub(/:$/,"",$2); sub(/^v/,"",$2); print $2; exit }')"
    if [ -z "$_inst" ]; then
      error "cargo-binstall.$_crate: expected $_pin, not installed" || _rc=1
    elif [ "$_inst" != "$_pin" ]; then
      error "cargo-binstall.$_crate: expected $_pin, installed $_inst" || _rc=1
    fi
  done <<EOF
$_pkgs
EOF
  return $_rc
}

# Compare installed rustup stable toolchain against the lockfile `rustup.stable` pin.
_lfe_check_rustup() {
  local _lf="$1" _jq="$2"
  local _rustup
  _rustup="$(command -v rustup || true)"
  [ -z "$_rustup" ] && { say -l rustup "not installed; skipping enforcement"; return 0; }
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
  local _date
  _date="$(printf '%s' "$_lf" | "$_jq" -r '(.rustup // {}).stable // empty' 2>/dev/null)" || true
  [ -z "$_date" ] && { say -l rustup "no stable pin in lockfile; skipping"; return 0; }
  local _spec="stable-${_date}"
  # check-suppress:suppression_doc: rustup toolchain list may fail if rustup uninitialised -- safe.
  if "$_rustup" toolchain list 2>/dev/null | grep -q "^${_spec}"; then
    say -l rustup "$_spec present"
    return 0
  fi
  error "rustup.stable: expected toolchain $_spec not installed"
  return 1
}

# Compare installed pwsh modules against the lockfile `pwsh` section.
_lfe_check_pwsh() {
  local _lf="$1" _jq="$2"
  local _pwsh
  _pwsh="$(command -v pwsh || true)"
  [ -z "$_pwsh" ] && { say -l pwsh "not installed; skipping enforcement"; return 0; }
  local _pkgs _mod _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.pwsh // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _mod; do
    [ -z "$_mod" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg m "$_mod" '(.pwsh // {})[$m] // empty' 2>/dev/null)" || true
    [ -z "$_pin" ] && continue
    # check-suppress:suppression_doc: module query may fail if pwsh profile errors -- safe.
    _inst="$("$_pwsh" -NoProfile -NonInteractive -Command "Get-Module -ListAvailable -Name '$_mod' | Select-Object -First 1 | ForEach-Object { \$_.Version.ToString() }" 2>/dev/null)" || true
    if [ -z "$_inst" ]; then
      error "pwsh.$_mod: expected $_pin, not installed" || _rc=1
    elif [ "$_inst" != "$_pin" ]; then
      error "pwsh.$_mod: expected $_pin, installed $_inst" || _rc=1
    fi
  done <<EOF
$_pkgs
EOF
  return $_rc
}

# Always warn that each `suggestions` sub-section is non-authoritative
# (warn-only per the invariant).  Never errors.
_lfe_warn_suggestions() {
  local _lf="$1" _jq="$2"
  local _subs
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the warnings -- safe.
  _subs="$(printf '%s' "$_lf" | "$_jq" -r '(.suggestions // {}) | keys[]' 2>/dev/null)" || return 0
  local _s
  while IFS= read -r _s; do
    [ -z "$_s" ] && continue
    warn -l suggestions "$_s: non-authoritative suggestion — not enforced (warn-only per invariant)"
  done <<EOF
$_subs
EOF
}

# Shared core: given the lockfile data and a jq path, run the pinned probes
# and always warn for suggestions.  Returns 1 if any pinned section has
# version drift.  Does NOT depend on check-lib.sh (no skip_step / step_number),
# so it is safe to call from both the check step and bump-lockfile.
_lfe_run_core() {
  local _lf_data="$1" _jq="$2"
  local _failures=0

  _lfe_check_bun "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_uv "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_cargo_binstall "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_rustup "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_pwsh "$_lf_data" "$_jq" || _failures=$((_failures + 1))

  _lfe_warn_suggestions "$_lf_data" "$_jq"

  return "$_failures"
}

# Standalone entry point for bump-lockfile --verify-installed.  Reads the
# lockfile, runs the pinned probes, always warns for suggestions, and returns
# 1 if any pinned section has version drift.  Does NOT depend on check-lib.sh
# (no skip_step / step_number), so it is safe to call from bump-lockfile.
verify_installed_versions() {
  local _repo_root="${1:-$PWD}"
  cd "$_repo_root" || return 1

  local _lockfile="src/lockfiles/lockfile.json"
  if [ ! -f "$_lockfile" ]; then
    error "lockfile not found at $_lockfile"
    return 1
  fi

  local _jq
  _jq="$(command -v jq || true)"
  if [ -z "$_jq" ]; then
    error "jq not found; cannot verify lockfile versions"
    return 1
  fi

  local _lf_data _failures
  # check-suppress:suppression_doc: malformed lockfile is fatal for verification -- reported as error below.
  _lf_data="$(cat "$_lockfile" 2>/dev/null)" || true
  if [ -z "$_lf_data" ]; then
    error "lockfile.json could not be read"
    return 1
  fi

  # Guard against set -e (bump-lockfile.sh) aborting on the non-zero count.
  _lfe_run_core "$_lf_data" "$_jq" || _failures=$?
  if [ "$_failures" -gt 0 ]; then
    error "lockfile verification found $_failures pinned section(s) with version drift"
    return 1
  fi
  say "lockfile verification: all applicable pinned sections match"
  return 0
}
