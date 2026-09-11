# shellcheck shell=bash
# Shared probe library for lockfile version enforcement.
#
# Provides the per-tool version probes (_lfe_check_*) and one entry point:
#   - verify_installed_versions : used by `update lockfile --verify-installed`;
#                                 standalone (no check-lib dependency) — reads
#                                 the lockfile, runs the pinned probes, always
#                                 warns for suggestions, returns 1 on drift.
#
# Probes are scoped to the packages the current host actually manages, read
# from the shared registry at src/modules/packages/desired.json.  A
# Windows-only package must never be reported as drift on macOS (and vice
# versa), so the desired set — not the lockfile section — decides what is
# probed.
#
# Requires: say, warn, error (from lib.sh / check-lib.sh) and jq on PATH.

# Emit the package names this host manages, keyed by manager, from the shared
# desired-package registry.  Fails loudly when the registry is unreadable: a
# silent fallback would re-introduce cross-host false drift.
_lfe_desired_names() {
  local _host="$1" _jq="$2"
  local _desired="src/modules/packages/desired.json"
  if [ ! -f "$_desired" ]; then
    error "desired package registry not found at $_desired"
    return 1
  fi
  local _desired_data
  if ! _desired_data="$(cat "$_desired")"; then
    error "desired package registry could not be read: $_desired"
    return 1
  fi
  # check-suppress:suppression_doc: jq parse failure on a malformed registry is reported as an error immediately below.
  local _names
  # shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
  if ! _names="$(printf '%s' "$_desired_data" | "$_jq" -c --arg h "$_host" '
      del(."$schema")
      | with_entries(.value = ((.value[$h] // []) | map(.name)))
    ')"; then
    error "desired package registry is malformed: $_desired"
    return 1
  fi
  printf '%s\n' "$_names"
}

# Emit the keys of one lockfile section that this host manages.  Empty output
# means the host manages nothing in that section, so the probe has nothing to
# check.
_lfe_scoped_keys() {
  local _lf="$1" _jq="$2" _section="$3" _desired="$4"
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  # shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
  printf '%s' "$_lf" | "$_jq" -r --arg s "$_section" --argjson d "$_desired" \
    '(.[$s] // {}) | keys[] as $k | select(($d[$s] // []) | index($k)) | $k' 2>/dev/null || return 0
}

# Compare installed bun global packages against the host's declared bun set.
# String pins are version-checked; object (VCS/rev) pins are not
# version-verifiable here and are skipped.  Returns 1 if any drift found.
_lfe_check_bun() {
  local _lf="$1" _jq="$2" _desired="$3"
  local _bun
  _bun="$(command -v bun || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_bun" ] && {
    say -l bun "not installed; skipping enforcement"
    return 0
  }
  local _global_json="$HOME/.bun/install/global/package.json"
  [ -f "$_global_json" ] || {
    say -l bun "no global package.json; skipping"
    return 0
  }
  local _installed
  # check-suppress:suppression_doc: malformed global package.json treats installed set as empty -- safe, drift is still reported below.
  _installed="$(cat "$_global_json" 2>/dev/null)" || true
  local _pkgs _pkg _pin _inst _rc=0
  _pkgs="$(_lfe_scoped_keys "$_lf" "$_jq" "bun" "$_desired")" || return 0
  while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_pkg" '(.bun // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    [ -z "$_pin" ] && continue
    # Object (VCS/rev) pins are not version-verifiable from the installed record.
    if [ "${_pin%"${_pin#?}"}" = '{' ]; then
      say -l bun "$_pkg: VCS-pinned (rev) — not version-verifiable, skipping"
      continue
    fi
    # check-suppress:suppression_doc: jq parse failure on a malformed installed record skips the comparison -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _inst="$(printf '%s' "$_installed" | "$_jq" -r --arg p "$_pkg" '(.dependencies // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed installed record skips the comparison -- safe.
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

# Compare installed uv tools against the host's declared uv set.
_lfe_check_uv() {
  local _lf="$1" _jq="$2" _desired="$3"
  local _uv
  _uv="$(command -v uv || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_uv" ] && {
    say -l uv "not installed; skipping enforcement"
    return 0
  }
  local _installed
  # check-suppress:suppression_doc: uv tool list may fail if no tool env initialised -- safe, drift reported below if parseable.
  _installed="$("$_uv" tool list 2>/dev/null)" || true
  [ -z "$_installed" ] && {
    say -l uv "no tools installed; skipping"
    return 0
  }
  local _pkgs _tool _pin _inst _rc=0
  _pkgs="$(_lfe_scoped_keys "$_lf" "$_jq" "uv" "$_desired")" || return 0
  while IFS= read -r _tool; do
    [ -z "$_tool" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_tool" '(.uv // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
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

# Compare installed cargo-binstall crates against the host's declared crate set.
_lfe_check_cargo_binstall() {
  local _lf="$1" _jq="$2" _desired="$3"
  local _cargo
  _cargo="$(command -v cargo || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_cargo" ] && {
    say -l cargo-binstall "cargo not installed; skipping enforcement"
    return 0
  }
  local _installed
  # check-suppress:suppression_doc: cargo install --list may fail if ~/.cargo uninitialised -- safe.
  _installed="$("$_cargo" install --list 2>/dev/null)" || true
  [ -z "$_installed" ] && {
    say -l cargo-binstall "no crates installed; skipping"
    return 0
  }
  local _pkgs _crate _pin _inst _rc=0
  _pkgs="$(_lfe_scoped_keys "$_lf" "$_jq" "cargo-binstall" "$_desired")" || return 0
  while IFS= read -r _crate; do
    [ -z "$_crate" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_crate" '(.["cargo-binstall"] // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
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
  _rustup="$(command -v rustup || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_rustup" ] && {
    say -l rustup "not installed; skipping enforcement"
    return 0
  }
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
  local _date
  _date="$(printf '%s' "$_lf" | "$_jq" -r '(.rustup // {}).stable // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
  [ -z "$_date" ] && {
    say -l rustup "no stable pin in lockfile; skipping"
    return 0
  }
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
  _pwsh="$(command -v pwsh || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_pwsh" ] && {
    say -l pwsh "not installed; skipping enforcement"
    return 0
  }
  local _pkgs _mod _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.pwsh // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _mod; do
    [ -z "$_mod" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg m "$_mod" '(.pwsh // {})[$m] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
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

# Compare the Nix-store symlink against the lockfile cursor.superpowers pin.
# The symlink at <nucleusUserRoot>/plugins/superpowers points into /nix/store/
# when the declarative builtins.fetchGit derivation has been evaluated.
# WHY: the user root is host-specific — macOS uses
# ~/Library/Application Support/nucleus, NixOS ~/.local/share/nucleus — so it is
# read from NUCLEUS_USER_ROOT, exported by src/scripts/lib/lib.sh, which every
# caller sources before loading this library.
_lfe_check_superpowers() {
  local _lf="$1" _jq="$2"
  if [ -z "${NUCLEUS_USER_ROOT:-}" ]; then
    error "NUCLEUS_USER_ROOT is unset; cannot locate the superpowers plugin (source src/scripts/lib/lib.sh first)"
    return 1
  fi
  local _plugin_dir="$NUCLEUS_USER_ROOT/plugins/superpowers"
  local _expected_rev _expected_source
  _expected_source="$(printf '%s' "$_lf" | "$_jq" -r '.cursor.superpowers.source // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
  _expected_rev="$(printf '%s' "$_lf" | "$_jq" -r '.cursor.superpowers.rev // empty' 2>/dev/null)" || true       # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
  [ -z "$_expected_rev" ] && {
    say -l superpowers "no superpowers pin in lockfile; skipping"
    return 0
  }
  if [ ! -L "$_plugin_dir" ]; then
    error "superpowers.$_expected_rev: plugin symlink not found at $_plugin_dir"
    return 1
  fi
  local _target
  _target="$(readlink "$_plugin_dir")"
  if [[ "$_target" != /nix/store/* ]]; then
    error "superpowers.$_expected_rev: symlink target $_target is not a Nix store path"
    return 1
  fi
  say -l superpowers "$_expected_rev present (store path: $_target)"
  return 0
}

# Warn-only probe for `suggestions.opencode` (editor plugins).  Checks
# that each managed plugin entry is present in the lockfile map and
# reports info-level messages for VCS-pinned entries that cannot be
# version-verified.  Never errors: opencode is a suggestions section
# (warn-only per the invariant).  Returns 0 always.
_lfe_check_opencode() {
  local _lf="$1" _jq="$2"
  local _oc
  _oc="$(command -v opencode || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_oc" ] && {
    say -l opencode "no opencode CLI; skipping suggestions.opencode verify"
    return 0
  }
  local _pkgs _pkg
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.suggestions.opencode // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    say -l opencode "$_pkg: VCS-pinned — not version-verifiable, skipping"
  done <<EOF
$_pkgs
EOF
  return 0
}

# Warn-only probe for `suggestions.vscode` (editor extensions).  Runs
# `code --list-extensions --show-versions` (fallback `code-insiders`) and
# compares each managed extension's installed version to the lockfile map.
# Never errors: vscode is a suggestions section (warn-only per the invariant)
# and is not actually locked on all platforms (POSIX locks via flake.lock).
# Skips gracefully when no `code` CLI is installed.  Returns 0 always.
_lfe_check_vscode() {
  local _lf="$1" _jq="$2"
  local _code
  _code="$(command -v code || command -v code-insiders || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_code" ] && {
    say -l vscode "no code CLI; skipping suggestions.vscode verify"
    return 0
  }
  local _installed
  # check-suppress:suppression_doc: code CLI failure yields empty installed set -- safe, drift is still reported below.
  _installed="$("$_code" --list-extensions --show-versions 2>/dev/null)" || true
  local _pkgs _pkg _pin _inst
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.suggestions.vscode // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_pkg" '(.suggestions.vscode // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    [ -z "$_pin" ] && continue
    # shellcheck disable=SC2016 # reason: extension id is a literal prefix match
    _inst="$(printf '%s\n' "$_installed" | awk -F'@' -v id="$_pkg" '$1==id {print $2; exit}')"
    if [ -z "$_inst" ]; then
      warn -l vscode "$_pkg: expected $_pin, not installed (warn-only)"
    elif [ "$_inst" != "$_pin" ]; then
      warn -l vscode "$_pkg: expected $_pin, installed $_inst (warn-only)"
    fi
  done <<EOF
$_pkgs
EOF
  return 0
}

# Warn-only probe for `suggestions.cursor` (editor extensions).  Runs
# `cursor --list-extensions --show-versions` and compares each managed
# extension's installed version to the lockfile map.  Never errors: cursor
# is a suggestions section (warn-only per the invariant).  Skips gracefully
# when no `cursor` CLI is installed.  Returns 0 always.
_lfe_check_cursor() {
  local _lf="$1" _jq="$2"
  local _cursor
  _cursor="$(command -v cursor || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_cursor" ] && {
    say -l cursor "no cursor CLI; skipping suggestions.cursor verify"
    return 0
  }
  local _installed
  # check-suppress:suppression_doc: cursor CLI failure yields empty installed set -- safe, drift is still reported below.
  _installed="$("$_cursor" --list-extensions --show-versions 2>/dev/null)" || true
  local _pkgs _pkg _pin _inst
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.suggestions.cursor // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_pkg" '(.suggestions.cursor // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    [ -z "$_pin" ] && continue
    # shellcheck disable=SC2016 # reason: extension id is a literal prefix match
    _inst="$(printf '%s\n' "$_installed" | awk -F'@' -v id="$_pkg" '$1==id {print $2; exit}')"
    if [ -z "$_inst" ]; then
      warn -l cursor "$_pkg: expected $_pin, not installed (warn-only)"
    elif [ "$_inst" != "$_pin" ]; then
      warn -l cursor "$_pkg: expected $_pin, installed $_inst (warn-only)"
    fi
  done <<EOF
$_pkgs
EOF
  return 0
}

# Shared core: given the lockfile data, the host key and a jq path, run the
# pinned probes scoped to the host's declared package set, and always warn for
# suggestions.  Returns 1 if any pinned section has version drift.
_lfe_run_core() {
  local _lf_data="$1" _jq="$2" _host="$3"
  local _failures=0

  local _desired
  if ! _desired="$(_lfe_desired_names "$_host" "$_jq")"; then
    return 1
  fi

  _lfe_check_bun "$_lf_data" "$_jq" "$_desired" || _failures=$((_failures + 1))
  _lfe_check_uv "$_lf_data" "$_jq" "$_desired" || _failures=$((_failures + 1))
  _lfe_check_cargo_binstall "$_lf_data" "$_jq" "$_desired" || _failures=$((_failures + 1))
  _lfe_check_rustup "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_pwsh "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_superpowers "$_lf_data" "$_jq" || _failures=$((_failures + 1))

  _lfe_check_opencode "$_lf_data" "$_jq"
  _lfe_check_vscode "$_lf_data" "$_jq"
  _lfe_check_cursor "$_lf_data" "$_jq"
  _lfe_warn_suggestions "$_lf_data" "$_jq"

  return "$_failures"
}

# Standalone entry point for `update lockfile --verify-installed`.  Reads the
# lockfile, runs the pinned probes scoped to the host's declared package set,
# always warns for suggestions, and returns 1 if any pinned section has version
# drift.
verify_installed_versions() {
  local _repo_root="${1:-$PWD}" _host="${2:-}"
  cd "$_repo_root" || return 1

  if [ -z "$_host" ]; then
    error "verify_installed_versions: host key required — pass \$(resolve_nucleus_host)"
    return 1
  fi

  local _lockfile="src/lockfiles/lockfile.json"
  if [ ! -f "$_lockfile" ]; then
    error "lockfile not found at $_lockfile"
    return 1
  fi

  local _jq
  _jq="$(command -v jq || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
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

  # Guard against set -e (update.sh) aborting on the non-zero count.
  _lfe_run_core "$_lf_data" "$_jq" "$_host" || _failures=$?
  if [ "$_failures" -gt 0 ]; then
    error "lockfile verification found $_failures pinned section(s) with version drift"
    return 1
  fi
  say "lockfile verification: all applicable pinned sections match"
  return 0
}
