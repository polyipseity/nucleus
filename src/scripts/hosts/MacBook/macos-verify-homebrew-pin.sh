#!/usr/bin/env sh
# Warn-only check that installed Homebrew versions match lockfile.
# Silent when all versions match.
# Takes repo root path as $1.
# Always exits 0 — this is a warning-only check that must not abort activation.

set -eu

_main() {
  LOCKFILE="${1:?repo root required}/src/lockfiles/lockfile.json"

if [ ! -f "$LOCKFILE" ]; then
  # Lockfile not present — nothing to verify.
  exit 0
fi

LOCKFILE_DATA="$(cat "$LOCKFILE")"
HAS_BREW="$(command -v brew >/dev/null 2>&1 && echo 1 || echo 0)"
HAS_MAS="$(command -v mas >/dev/null 2>&1 && echo 1 || echo 0)"
WARNINGS=""
# POSIX-compliant newline literal
NL='
'

# Pre-extract keys to avoid POSIX-unfriendly process substitution
BREW_KEYS="$(printf '%s' "$LOCKFILE_DATA" | jq -r '(.homebrew.brews // {}) | keys[]')"
CASK_KEYS="$(printf '%s' "$LOCKFILE_DATA" | jq -r '(.homebrew.casks // {}) | keys[]')"
MAS_KEYS="$(printf '%s' "$LOCKFILE_DATA" | jq -r '(.homebrew.masApps // {}) | keys[]')"

if [ "$HAS_BREW" -eq 1 ]; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    expected="$(printf '%s' "$LOCKFILE_DATA" | jq -r --arg k "$key" '(.homebrew.brews // {})[$k] // empty')"
    [ -z "$expected" ] && continue
    # undoc-supp: package may not be installed; brew list exits 1 for absent items.
    installed="$(brew list --versions "$key" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -n "$installed" ] && [ "$installed" != "$expected" ]; then
      WARNINGS="${WARNINGS}  homebrew.brews.$key: expected $expected, installed $installed${NL}"
    fi
  done <<KEYEOF
$BREW_KEYS
KEYEOF
fi

if [ "$HAS_BREW" -eq 1 ]; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    expected="$(printf '%s' "$LOCKFILE_DATA" | jq -r --arg k "$key" '(.homebrew.casks // {})[$k] // empty')"
    [ -z "$expected" ] && continue
    # undoc-supp: cask may not be installed; brew list exits 1 for absent items.
    installed="$(brew list --cask --versions "$key" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -n "$installed" ] && [ "$installed" != "$expected" ]; then
      WARNINGS="${WARNINGS}  homebrew.casks.$key: expected $expected, installed $installed${NL}"
    fi
  done <<KEYEOF
$CASK_KEYS
KEYEOF
fi

if [ "$HAS_MAS" -eq 1 ]; then
  # undoc-supp: mas app may not be installed; mas list exits 1 for absent items.
  mas_list="$(mas list 2>/dev/null || true)"
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    expected="$(printf '%s' "$LOCKFILE_DATA" | jq -r --arg k "$key" '(.homebrew.masApps // {})[$k] // empty')"
    [ -z "$expected" ] && continue
    # mas list format: "id appname (version)" or "id appname (???)"
    installed="$(printf '%s' "$mas_list" | awk -v name="$key" -F'[()]' '$0 ~ name {print $2}' | head -1 | tr -d '[:space:]')"
    if [ -n "$installed" ] && [ "$installed" != "$expected" ]; then
      WARNINGS="${WARNINGS}  homebrew.masApps.$key: expected $expected, installed $installed${NL}"
    fi
  done <<KEYEOF
$MAS_KEYS
KEYEOF
fi

  if [ -n "$WARNINGS" ]; then
    echo "homebrew: package version(s) differ from lockfile (nix-homebrew may be out of sync):" >&2
    printf '%s' "$WARNINGS" >&2
  fi
}

_main "$@" || true  # undoc-supp: warning-only check; must not abort activation
