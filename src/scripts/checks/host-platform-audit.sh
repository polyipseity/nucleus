#!/usr/bin/env bash
# host-platform-audit.sh — Classify host vs platform vs implementation naming (read-only).
# See .agents/instructions/host-platform-audit.instructions.md
# Exit 0 when no VIOLATION; non-zero on VIOLATION. WARN does not fail.

set -euo pipefail

_REPO_ROOT="${1:-}"
if [ -z "$_REPO_ROOT" ]; then
  printf '%s\n' "host-platform-audit: repo root required" >&2
  exit 2
fi
cd "$_REPO_ROOT" || exit 2

_VIOLATIONS=0
_WARNS=0
_PASSES=0

_audit_pass() {
  printf 'PASS  %s\n' "$1"
  _PASSES=$((_PASSES + 1))
}

_audit_warn() {
  printf 'WARN  %s\n' "$1"
  _WARNS=$((_WARNS + 1))
}

_audit_violation() {
  printf 'VIOLATION  %s\n' "$1"
  _VIOLATIONS=$((_VIOLATIONS + 1))
}

# ── F1: legacy identifiers ──────────────────────────────────────────
_f1_hits=$(
  rg -n 'currentOs|CURRENT_OS|macOSAllVars|usersMacOS|NUCLEUS_PLATFORM|\bPLATFORM=' \
    --glob '!src/scripts/checks/check-steps/26-host-os-naming.*' \
    --glob '!src/scripts/checks/host-platform-audit.sh' \
    --glob '!**/*.instructions.md' \
    2>/dev/null || true
)
if [ -n "$_f1_hits" ]; then
  _audit_violation "F1 legacy identifiers:${_f1_hits}"
else
  _audit_pass "F1 legacy identifiers"
fi

# ── F2: services.json platforms key ─────────────────────────────────
if jq -e '
  to_entries[]
  | select(.key | startswith("$") | not)
  | select(.value | type == "object")
  | select(.value | has("platforms"))
' src/modules/services.json >/dev/null 2>&1; then
  _audit_violation "F2 services.json legacy platforms key"
else
  _audit_pass "F2 services.json no legacy platforms key"
fi

# ── F3: env-catalog values.macOS ────────────────────────────────────
_f3_hits=$(rg -n 'values\.macOS' src/modules/lib/env-catalog.nix 2>/dev/null || true)
if [ -n "$_f3_hits" ]; then
  _audit_violation "F3 env-catalog values.macOS:${_f3_hits}"
else
  _audit_pass "F3 env-catalog host keys"
fi

# ── F4: flake lowercase attrs ───────────────────────────────────────
_f4_hits=$(
  rg -n 'darwinConfigurations\.(macbook|macBook|macos)|nixosConfigurations\.(nixos|nixOS|linux)' \
    src/flake.nix 2>/dev/null || true
)
if [ -n "$_f4_hits" ]; then
  _audit_violation "F4 flake lowercase attrs:${_f4_hits}"
else
  _audit_pass "F4 flake host attrs"
fi

# ── F5: user registry lowercase host keys ───────────────────────────
_f5_hits=$(rg -n '"(macos|nixos|windows)"\s*:' src/users/ 2>/dev/null || true)
if [ -n "$_f5_hits" ]; then
  _audit_violation "F5 user registry lowercase host keys:${_f5_hits}"
else
  _audit_pass "F5 user registry host keys"
fi

# ── F6: git-tracked config path host casing ─────────────────────────
_f6_hits=$(
  git ls-files 'src/modules/configs/**' 2>/dev/null \
    | rg '/(macos|nixos|windows)/|config-(macos|nixos|windows)\.' || true
)
if [ -n "$_f6_hits" ]; then
  _audit_violation "F6 config path host casing (git index):${_f6_hits}"
else
  _audit_pass "F6 config path host casing (git index)"
fi

# ── F7: code references to lowercase host config paths ────────────────
_f7_hits=$(
  rg -n 'configs/(macos|nixos|windows)/|config-(macos|nixos|windows)\.' src/ scripts/ 2>/dev/null || true
)
if [ -n "$_f7_hits" ]; then
  _audit_violation "F7 code lowercase host config refs:${_f7_hits}"
else
  _audit_pass "F7 code host config refs"
fi

# ── F8: test path casing for nixos-domain.xml ───────────────────────
_f8_hits=$(
  rg -n 'NixOS-domain\.xml' tests/ 2>/dev/null || true
)
if [ -n "$_f8_hits" ]; then
  _audit_violation "F8 test references NixOS-domain.xml (use nixos-domain.xml):${_f8_hits}"
else
  _audit_pass "F8 vm domain xml test path"
fi

# ── A: host-keyed config inventory ──────────────────────────────────
_a_missing=0
for _path in \
  src/modules/configs/camilladsp/configs/MacBook/config.yml \
  src/modules/configs/camilladsp/configs/NixOS/config.yml \
  src/modules/configs/camilladsp/configs/Windows/config.yml \
  src/modules/configs/camillagui-backend/config-MacBook.yml \
  src/modules/configs/camillagui-backend/config-NixOS.yml \
  src/modules/configs/camillagui-backend/config-Windows.yml; do
  if ! git ls-files --error-unmatch "$_path" >/dev/null 2>&1; then
    _audit_violation "A missing host-keyed config: $_path"
    _a_missing=$((_a_missing + 1))
  fi
done
if [ "$_a_missing" -eq 0 ]; then
  _audit_pass "A host-keyed config inventory"
fi

# ── F9: host identity bypass (current_os, uname→host, IsOSPlatform *Host) ─
_f9a_hits=$(rg -n 'current_os=|currentOs' scripts/ 2>/dev/null || true)
if [ -n "$_f9a_hits" ]; then
  _audit_violation "F9a legacy current_os/currentOs in scripts/:${_f9a_hits}"
else
  _audit_pass "F9a no legacy current_os in scripts/"
fi

_f9b_allowlist=(
  'src/scripts/lib/lib.sh'
  'src/scripts/apply.sh'
  'src/scripts/lib/vm.sh'
)
_f9b_hits=$(
  {
    rg -n 'Darwin\).*(MacBook|NixOS)|Linux\).*(MacBook|NixOS)' scripts/ src/scripts/ 2>/dev/null || true
  } | while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _f="${_line%%:*}"
    _allowed=false
    for _b in "${_f9b_allowlist[@]}"; do
      if [ "$_f" = "$_b" ]; then
        _allowed=true
        break
      fi
    done
    if [ "$_allowed" = false ]; then
      printf '%s\n' "$_line"
    fi
  done
)
if [ -n "$_f9b_hits" ]; then
  _audit_violation "F9b uname→host outside allowlist:${_f9b_hits}"
else
  _audit_pass "F9b uname→host boundary"
fi

_f9c_hits=$(
  rg -n '\w+Host\s*=.*IsOSPlatform' src/hosts/Windows/modules/ 2>/dev/null || true
)
if [ -n "$_f9c_hits" ]; then
  _audit_violation "F9c IsOSPlatform *Host in Windows modules:${_f9c_hits}"
else
  _audit_pass "F9c no IsOSPlatform *Host"
fi

# ── C: stdenv/uname outside boundary allowlist (WARN) ───────────────
_boundary_globs=(
  'src/scripts/lib/lib.sh'
  'src/scripts/apply.sh'
  'src/modules/lib/host-platform.nix'
  'scripts/vm.sh'
  'src/scripts/lib/vm.sh'
  'src/scripts/lib/macos-launch-services.sh'
  'src/modules/core.nix'
  'src/modules/macos.nix'
  'src/modules/linux.nix'
)
_c_stdenv_hits=$(
  rg -l 'stdenv\.isDarwin|stdenv\.isLinux' src/modules/ src/flake.nix 2>/dev/null \
    | while IFS= read -r _f; do
      _allowed=false
      for _b in "${_boundary_globs[@]}"; do
        if [ "$_f" = "$_b" ] || [[ "$_f" == src/modules/posix-* ]]; then
          _allowed=true
          break
        fi
      done
      if [ "$_allowed" = false ]; then
        printf '%s\n' "$_f"
      fi
    done
)
if [ -n "$_c_stdenv_hits" ]; then
  _audit_warn "C stdenv outside allowlist (triage):${_c_stdenv_hits}"
else
  _audit_pass "C stdenv boundary allowlist"
fi

printf '\nhost-platform-audit: %d pass, %d warn, %d violation\n' "$_PASSES" "$_WARNS" "$_VIOLATIONS"

if [ "$_VIOLATIONS" -gt 0 ]; then
  exit 1
fi
exit 0
