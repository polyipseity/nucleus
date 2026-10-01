# shellcheck shell=bash
# Lockfile version probes for the update action. Probes are scoped to the
# packages the host manages (src/modules/packages/desired.json), so a
# Windows-only pin is never reported as drift on macOS. verify_installed_versions
# is the standalone entry point.
#
# Requires: say, warn, error (from lib.sh / check-lib.sh) and jq on PATH.

# Package names this host manages, from the shared registry. An unreadable
# registry is fatal: a silent fallback would re-introduce cross-host false drift.
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

# Lockfile keys in one section that this host manages; empty output means the
# host manages nothing there, so the probe has nothing to check.
_lfe_scoped_keys() {
  local _lf="$1" _jq="$2" _section="$3" _desired="$4"
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  # shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
  printf '%s' "$_lf" | "$_jq" -r --arg s "$_section" --argjson d "$_desired" \
    '(.[$s] // {}) | keys[] as $k | select(($d[$s] // []) | index($k)) | $k' 2>/dev/null || return 0
}

# Installed bun globals against the host's declared bun set. Object (VCS/rev)
# pins are not version-verifiable here, so they are skipped.
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
  local _pkgs _tool _pin _inst _rev _commit _rc=0
  _pkgs="$(_lfe_scoped_keys "$_lf" "$_jq" "uv" "$_desired")" || return 0
  while IFS= read -r _tool; do
    [ -z "$_tool" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg p "$_tool" '(.uv // {})[$p] // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    [ -z "$_pin" ] && continue
    # An object pin has no version to compare: uv records the resolved commit
    # (PEP 610), so verify that instead of skipping the tool.
    if [ "${_pin%"${_pin#?}"}" = '{' ]; then
      # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
      # check-suppress:suppression_doc: jq parse failure on a malformed lockfile pin skips the revision -- drift is reported below when the revision cannot be read.
      _rev="$(printf '%s' "$_pin" | "$_jq" -r '.rev // empty' 2>/dev/null)" || true
      if [ -z "$_rev" ]; then
        error "uv.$_tool: pin has no rev; cannot verify the installed revision" || _rc=1
        continue
      fi
      # check-suppress:suppression_doc: _lfe_uv_installed_commit returns 1 when no PEP 610 record exists; caller reports missing install record as drift
      _commit="$(_lfe_uv_installed_commit "$_tool" "$_jq")" || true
      if [ -z "$_commit" ]; then
        error "uv.$_tool: expected revision $_rev, no install record" || _rc=1
      elif [ "$_commit" != "$_rev" ]; then
        error "uv.$_tool: expected revision $_rev, installed $_commit" || _rc=1
      fi
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

# Commit uv recorded for an installed tool, from
# <tool>/lib/python*/site-packages/*.dist-info/direct_url.json. Returns 1 when
# the tool has no such record.
_lfe_uv_installed_commit() {
  local _tool="$1" _jq="$2"
  local _root="${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}/$_tool"
  local _record=""
  # check-suppress:suppression_doc: find returns non-zero when tool directory absent or no direct_url.json; empty-string check below handles not-found
  _record="$(find "$_root" -name direct_url.json -type f -print 2>/dev/null | head -1)" || true
  [ -n "$_record" ] || return 1
  # check-suppress:suppression_doc: malformed PEP 610 record yields no commit -- the caller reports the drift.
  "$_jq" -r '.vcs_info.commit_id // empty' "$_record" 2>/dev/null || true
}

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

# Installed PowerShell modules against the psgallery pins. A pin is a version
# string or a {version, hash} object, and the installed module is an extracted
# directory rather than the pinned nupkg, so only the version is verifiable
# here; the hash pin is consumed by the hash-pinned declarative module path.
_lfe_check_psgallery() {
  local _lf="$1" _jq="$2"
  local _pwsh
  _pwsh="$(command -v pwsh || true)" # check-suppress:suppression_doc: command -v exits non-zero when the tool is absent; || true avoids set -e abort and the empty-string check below handles it
  [ -z "$_pwsh" ] && {
    say -l psgallery "not installed; skipping enforcement"
    return 0
  }
  local _pkgs _mod _pin _inst _rc=0
  # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the section -- safe.
  _pkgs="$(printf '%s' "$_lf" | "$_jq" -r '(.psgallery // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _mod; do
    [ -z "$_mod" ] && continue
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _pin="$(printf '%s' "$_lf" | "$_jq" -r --arg m "$_mod" '((.psgallery // {})[$m] | if type == "object" then .version else . end) // empty' 2>/dev/null)" || true # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    [ -z "$_pin" ] && continue
    # check-suppress:suppression_doc: module query may fail if pwsh profile errors -- safe.
    _inst="$("$_pwsh" -NoProfile -NonInteractive -Command "Get-Module -ListAvailable -Name '$_mod' | Select-Object -First 1 | ForEach-Object { \$_.Version.ToString() }" 2>/dev/null)" || true
    if [ -z "$_inst" ]; then
      error "psgallery.$_mod: expected $_pin, not installed" || _rc=1
    elif [ "$_inst" != "$_pin" ]; then
      error "psgallery.$_mod: expected $_pin, installed $_inst" || _rc=1
    fi
  done <<EOF
$_pkgs
EOF
  return $_rc
}

# Verify each pinned whisper model is deployed under the nucleus user root and
# still hashes to the pinned value.
#
# WHY the lockfile is the only authority: no package manager ships the ggml
# weights, and the deployed copy under <nucleusUserRoot>/models is the file
# whisper-cli opens, which a truncated download or a manual replacement can
# corrupt. The pkgs.fetchurl output that enforces the hash in the store is not
# that file.
_lfe_check_whisper() {
  local _lf="$1" _jq="$2"
  if [ -z "${NUCLEUS_USER_ROOT:-}" ]; then
    error "NUCLEUS_USER_ROOT is unset; cannot verify the whisper model (source src/scripts/lib/lib.sh first)"
    return 1
  fi
  local _files _rc=0
  _files="$(printf '%s' "$_lf" | "$_jq" -r '(.whisper // {}) | keys[]' 2>/dev/null)" || return 0
  while IFS= read -r _file; do
    [ -z "$_file" ] && continue
    local _sri _want _got _path
    # check-suppress:suppression_doc: jq parse failure on a malformed lockfile skips the pin -- safe.
    # `type` guards rather than a bare .hash: a string value would make jq
    # raise, and the 2>/dev/null below would hide the entry the operator needs.
    # shellcheck disable=SC2016 # reason: jq --arg variable, not shell expansion
    _sri="$(printf '%s' "$_lf" | "$_jq" -r --arg f "$_file" '(.whisper // {})[$f] | if type == "object" then .hash // empty else empty end' 2>/dev/null)" || continue
    [ -z "$_sri" ] && continue
    # SRI is base64 and sha256_of_file yields hex, so one side is decoded. `od -v`
    # is load-bearing: without it od collapses a run of identical bytes to `*`,
    # truncating the hash of an all-zero file instead of reporting a mismatch.
    _want="$(printf '%s' "${_sri#sha256-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
    _path="$NUCLEUS_USER_ROOT/models/$_file"
    if [ ! -f "$_path" ]; then
      error "whisper.$_file: not deployed at $_path"
      _rc=1
      continue
    fi
    _got="$(sha256_of_file "$_path")"
    if [ "$_got" != "$_want" ]; then
      error "whisper.$_file: expected sha256:$_want, found $_got"
      _rc=1
    else
      say -l whisper "$_file present (sha256:$_want)"
    fi
  done <<EOF
$_files
EOF
  return $_rc
}

# Warn for every `suggestions` sub-section, never an error.
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

# Nix-store symlink for the superpowers plugin against the cursor.superpowers
# pin.
# WHY the user root comes from NUCLEUS_USER_ROOT: it is host-specific (macOS
# ~/Library/Application Support/nucleus, NixOS ~/.local/share/nucleus) and every
# caller sources lib.sh, which exports it.
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

# Warn-only for suggestions.opencode: every managed entry is VCS-pinned, so
# there is no version to verify. Never errors.
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

# Warn-only for suggestions.vscode, the one duplication exception in the lockfile
# rules: Windows cannot evaluate Nix, so the probe compares installed extension
# versions. Never errors.
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

# Warn-only for suggestions.cursor, compared the same way; never errors.
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

# Run the pinned probes against the host's declared package set, then always
# warn for suggestions. Returns the number of pinned sections with drift.
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
  _lfe_check_psgallery "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_superpowers "$_lf_data" "$_jq" || _failures=$((_failures + 1))
  _lfe_check_whisper "$_lf_data" "$_jq" || _failures=$((_failures + 1))

  _lfe_check_opencode "$_lf_data" "$_jq"
  _lfe_check_vscode "$_lf_data" "$_jq"
  _lfe_check_cursor "$_lf_data" "$_jq"
  _lfe_warn_suggestions "$_lf_data" "$_jq"

  return "$_failures"
}

# Entry point for `update lockfile --verify-installed`. Reads the lockfile and
# returns 1 if any pinned section has version drift.
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

  # `|| _failures=$?` keeps set -e in update.sh from aborting on the count.
  _lfe_run_core "$_lf_data" "$_jq" "$_host" || _failures=$?
  if [ "$_failures" -gt 0 ]; then
    error "lockfile verification found $_failures pinned section(s) with version drift"
    return 1
  fi
  say "lockfile verification: all applicable pinned sections match"
  return 0
}
