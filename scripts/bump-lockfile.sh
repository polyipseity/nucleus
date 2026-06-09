#!/usr/bin/env bash
# bump-lockfile.sh — Bump version pins in the consolidated lockfile.
#
# Reads src/lockfiles/lockfile.json, queries each available tool for the
# current installed/published version of each pinned item, and writes an
# updated lockfile atomically.
#
# Sections:
#   winget        winget show --id <id>     (skip if winget unavailable)
#   scoop         scoop info <pkg>          (skip if scoop unavailable)
#   cargo-binstall Keep current version     (no reliable CLI query)
#   bun           npm view <pkg> version    (skip if bun unavailable)
#   uv            uv tool list              (skip if uv unavailable)
#   rustup        rustc +<ch> --version     (skip if rustup unavailable)
#   pwsh          Find-Module via pwsh      (skip if pwsh unavailable)
#   vscode        code/code-insiders --list-extensions --show-versions
#                 (skip if neither available)
#   ollama        ollama show <name>:<tag> --format json
#                 (skip if ollama unavailable)
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on failure (missing jq, lockfile not found).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT="$(resolve_nucleus_root)"
LOCKFILE_REL="src/lockfiles/lockfile.json"
LOCKFILE_ABS="$REPO_ROOT/$LOCKFILE_REL"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_command jq

if [ ! -f "$LOCKFILE_ABS" ]; then
  printf '%s\n' "bump-lockfile: error: lockfile not found at $LOCKFILE_ABS" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_update() {
  printf 'bump-lockfile: updating %s.%s from %s to %s\n' "$1" "$2" "$3" "$4"
}

log_skip() {
  printf 'bump-lockfile: %s not available, skipping %s section\n' "$1" "$2"
}

log_skip_all() {
  printf 'bump-lockfile: skipping %s section\n' "$1"
}

# ---------------------------------------------------------------------------
# Read lockfile
# ---------------------------------------------------------------------------
data=$(cat "$LOCKFILE_ABS")

# Update timestamp to current UTC ISO 8601
data=$(printf '%s\n' "$data" | jq --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated = $d')

# ---------------------------------------------------------------------------
# winget — winget show --id <id>
# ---------------------------------------------------------------------------
if command -v winget >/dev/null 2>&1; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.winget // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(winget show --id "$key" 2>/dev/null | awk -F': ' '/^Version / {print $2}' | head -1 | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "winget" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.winget[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.winget // {}) | keys[]')
else
  log_skip "winget" "winget"
fi

# ---------------------------------------------------------------------------
# scoop — scoop info <pkg>
# ---------------------------------------------------------------------------
if command -v scoop >/dev/null 2>&1; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.scoop // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(scoop info "$key" 2>/dev/null | awk -F': ' '/^Version / {print $2}' | head -1 | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "scoop" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.scoop[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.scoop // {}) | keys[]')
else
  log_skip "scoop" "scoop"
fi

# ---------------------------------------------------------------------------
# cargo-binstall — keep current version (no reliable CLI query)
# ---------------------------------------------------------------------------
log_skip_all "cargo-binstall (no reliable CLI query available)"

# ---------------------------------------------------------------------------
# bun — npm view <pkg> version, gated on bun availability
# ---------------------------------------------------------------------------
if command -v bun >/dev/null 2>&1; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.bun // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(npm view "$key" version 2>/dev/null | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "bun" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.bun[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.bun // {}) | keys[]')
else
  log_skip "bun" "bun"
fi

# ---------------------------------------------------------------------------
# uv — uv tool list
# ---------------------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
  # Build a map of package-name -> version from uv tool list.
  # Typical output: "pkgname@version" or "pkgname v1.0.0".
  declare -A uv_installed=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Strip leading "- " or bullet, then split on '@' or whitespace+version prefix.
    line="${line#- }"
    line="${line#* }"
    if echo "$line" | grep -q '@'; then
      pkg="${line%%@*}"
      ver="${line#*@}"
    else
      # "pkgname v1.0.0" — version after space, stripped of leading 'v'
      pkg="${line%% *}"
      ver="${line#* }"
    fi
    ver="${ver#v}"
    [ -n "$pkg" ] && [ -n "$ver" ] && uv_installed["$pkg"]="$ver"
  done < <(uv tool list 2>/dev/null || true)

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.uv // {})[$k] // empty')
    [ -z "$old" ] && continue
    new="${uv_installed[$key]:-}"
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "uv" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.uv[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.uv // {}) | keys[]')
else
  log_skip "uv" "uv"
fi

# ---------------------------------------------------------------------------
# rustup — rustc +<channel> --version
# ---------------------------------------------------------------------------
if command -v rustup >/dev/null 2>&1; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.rustup // {})[$k] // empty')
    [ -z "$old" ] && continue
    # Check if the toolchain is installed before querying
    if rustup toolchain list 2>/dev/null | grep -q "^$key"; then
      new=$(rustc "+$key" --version 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
      if [ -n "$new" ] && [ "$new" != "$old" ]; then
        log_update "rustup" "$key" "$old" "$new"
        data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.rustup[$k] = $v')
      fi
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.rustup // {}) | keys[]')
else
  log_skip "rustup" "rustup"
fi

# ---------------------------------------------------------------------------
# pwsh — Find-Module via pwsh -NoProfile
# ---------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.pwsh // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(pwsh -NoProfile -Command "Find-Module -Name '$key' | Select-Object -ExpandProperty Version" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "pwsh" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.pwsh[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.pwsh // {}) | keys[]')
else
  log_skip "pwsh" "pwsh"
fi

# ---------------------------------------------------------------------------
# homebrew — brew list --versions, brew list --cask --versions
# ---------------------------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  # brews
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.homebrew.brews // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(brew list --versions 2>/dev/null | awk -v k="$key" '$1 == k {print $2}' | head -1 | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "homebrew.brews" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.homebrew.brews[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.homebrew.brews // {}) | keys[]')

  # casks
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.homebrew.casks // {})[$k] // empty')
    [ -z "$old" ] && continue
    new=$(brew list --cask --versions 2>/dev/null | awk -v k="$key" '$1 == k {print $2}' | head -1 | tr -d '[:space:]')
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "homebrew.casks" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.homebrew.casks[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.homebrew.casks // {}) | keys[]')
else
  log_skip "brew" "homebrew"
fi

# ---------------------------------------------------------------------------
# vscode — code / code-insiders --list-extensions --show-versions
# ---------------------------------------------------------------------------
vscode_output=""
if command -v code >/dev/null 2>&1; then
  vscode_output=$(code --list-extensions --show-versions 2>/dev/null || true)
elif command -v code-insiders >/dev/null 2>&1; then
  vscode_output=$(code-insiders --list-extensions --show-versions 2>/dev/null || true)
fi

if [ -n "$vscode_output" ]; then
  # Build map: extension-id -> version
  declare -A vscode_exts=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *@*)
        pkg="${line%%@*}"
        ver="${line#*@}"
        [ -n "$pkg" ] && [ -n "$ver" ] && vscode_exts["$pkg"]="$ver"
        ;;
    esac
  done <<< "$vscode_output"

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.vscode // {})[$k] // empty')
    [ -z "$old" ] && continue
    new="${vscode_exts[$key]:-}"
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "vscode" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.vscode[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.vscode // {}) | keys[]')
else
  log_skip "vscode" "vscode"
fi

# ---------------------------------------------------------------------------
# ollama — ollama show <name>:<tag> --format json
# ---------------------------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
  # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
  # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    # Get the array index to iterate over models for this host
    model_count=$(printf '%s\n' "$data" | jq -r --arg h "$host" '(.ollama[$h] // []) | length')
    [ "$model_count" -eq 0 ] && continue

    for idx in $(seq 0 $((model_count - 1))); do
      entry=$(printf '%s\n' "$data" | jq -c --arg h "$host" --argjson i "$idx" '(.ollama[$h] // [])[$i]')
      [ -z "$entry" ] && continue

      name=$(printf '%s\n' "$entry" | jq -r '.name // empty')
      tag=$(printf '%s\n' "$entry" | jq -r '.tag // empty')
      [ -z "$name" ] || [ -z "$tag" ] && continue

      old_digest=$(printf '%s\n' "$entry" | jq -r '.digest // empty')

      # Query ollama for current model info
      ollama_info=$(OLLAMA_HOST="127.0.0.1:11434" ollama show "$name:$tag" --format json 2>/dev/null || true)
      if [ -n "$ollama_info" ]; then
        new_digest=$(printf '%s\n' "$ollama_info" | jq -r '.digest // empty' 2>/dev/null || true)
        if [ -n "$new_digest" ] && [ "$new_digest" != "$old_digest" ]; then
          log_update "ollama ($host)" "$name:$tag" "${old_digest:-none}" "$new_digest"
          if [ -n "$old_digest" ]; then
            # Update digest for entry that already has it
            data=$(printf '%s\n' "$data" | jq --arg h "$host" --arg n "$name" --arg t "$tag" --arg d "$new_digest" '
              .ollama[$h] |= map(
                if .name == $n and .tag == $t then
                  .digest = $d
                else
                  .
                end
              )
            ')
          else
            # Add digest field for entries that don't have one yet
            data=$(printf '%s\n' "$data" | jq --arg h "$host" --arg n "$name" --arg t "$tag" --arg d "$new_digest" '
              .ollama[$h] |= map(
                if .name == $n and .tag == $t then
                  .digest = $d
                else
                  .
                end
              )
            ')
          fi
        fi
      fi
    done
  done < <(printf '%s\n' "$data" | jq -r '(.ollama // {}) | keys[]')
else
  log_skip "ollama" "ollama"
fi

# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------
tmpfile=$(mktemp "$LOCKFILE_ABS.tmp.XXXXXX")
# shellcheck disable=SC2064
trap "rm -f '$tmpfile'" EXIT

printf '%s\n' "$data" > "$tmpfile"
mv -- "$tmpfile" "$LOCKFILE_ABS"

printf 'bump-lockfile: wrote %s\n' "$LOCKFILE_REL"
