#!/usr/bin/env bash
# bump-lockfile.sh — Bump version pins in the consolidated lockfile.
#
# Reads src/lockfiles/lockfile.json, queries each available tool for the
# current installed/published version of each pinned item, and writes an
# updated lockfile atomically.
#
# Sections (pass comma-separated via --sections to update selectively):
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
#   vm-setup      VM image artifact pins (nixos-iso, tart-images, windows). Use --sections nixos-iso etc. for sub-sections.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT      Override the detected repository root path.
#   NUCLEUS_OLLAMA_HOST    Ollama daemon address (host:port) for admin CLI commands (default: read from services.json).
#
# Flags:
#   --sections <list>  Comma-separated list of sections to update (default: all)
#   --help             Show this help
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

# Parse --sections flag (comma-separated, defaults to all)
SECTIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sections)
      shift
      SECTIONS="$1"
      ;;
    --help)
      grep '^#' "$0" | sed 's/^# \?//' | sed 's/^#//'
      exit 0
      ;;
    *)
      printf 'bump-lockfile: unknown flag: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

section_enabled() {
  local name="$1"
  [ -z "$SECTIONS" ] && return 0  # no filter = all enabled
  case ",$SECTIONS," in
    *",$name,"*) return 0 ;;
    *) return 1 ;;
  esac
}

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
if section_enabled winget && command -v winget >/dev/null 2>&1; then
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
if section_enabled scoop && command -v scoop >/dev/null 2>&1; then
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
if section_enabled cargo-binstall; then
  log_skip_all "cargo-binstall (no reliable CLI query available)"
fi

# ---------------------------------------------------------------------------
# bun — npm view <pkg> version, gated on bun availability
# ---------------------------------------------------------------------------
if section_enabled bun && command -v bun >/dev/null 2>&1; then
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
if section_enabled uv && command -v uv >/dev/null 2>&1; then
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
if section_enabled rustup && command -v rustup >/dev/null 2>&1; then
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
if section_enabled pwsh && command -v pwsh >/dev/null 2>&1; then
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
if section_enabled homebrew && command -v brew >/dev/null 2>&1; then
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
if section_enabled vscode; then
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
fi

# ---------------------------------------------------------------------------
# ollama — ollama show <name>:<tag> --format json
# ---------------------------------------------------------------------------
: "${NUCLEUS_OLLAMA_HOST:=$(jq -r '.ollama.network.default | "\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo "127.0.0.1:11434")}"
if section_enabled ollama && command -v ollama >/dev/null 2>&1; then
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
      ollama_info=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama show "$name:$tag" --format json 2>/dev/null || true)
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
# nixos-iso — Query NixOS channel for latest ISO URL and its SHA-256
# ---------------------------------------------------------------------------
if section_enabled vm-setup || section_enabled nixos-iso; then
  while IFS= read -r arch; do
    [ -z "$arch" ] && continue
    old_url=$(printf '%s\n' "$data" | jq -r --arg a "$arch" '(.vm-setup.nixos-iso // {})[$a].url // empty')
    old_digest=$(printf '%s\n' "$data" | jq -r --arg a "$arch" '(.vm-setup.nixos-iso // {})[$a].digest // empty')
    [ -z "$old_url" ] && continue

    # Resolve the latest- redirect to a specific release URL
    latest_url="https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-${arch}.iso"
    resolved_url=$(curl -sIL "$latest_url" 2>/dev/null | grep -i "^location:" | tail -1 | tr -d '[:space:]' | sed 's/^location://I')
    if [ -z "$resolved_url" ]; then
      printf 'bump-lockfile: warning: could not resolve %s for %s\n' "$latest_url" "$arch" >&2
      continue
    fi

    # Fetch the SHA-256 checksum from the .sha256 sidecar
    sha256_url="${resolved_url}.sha256"
    sha256_content=$(curl -sL "$sha256_url" 2>/dev/null || true)
    new_sha256=$(printf '%s\n' "$sha256_content" | grep -oE '^[0-9a-f]{64}' | head -1)
    if [ -z "$new_sha256" ]; then
      printf 'bump-lockfile: warning: could not fetch checksum for %s (%s)\n' "$arch" "$sha256_url" >&2
      continue
    fi
    new_digest="sha256:$new_sha256"

    if [ "$old_url" != "$resolved_url" ] || [ "$old_digest" != "$new_digest" ]; then
      log_update "vm-setup.nixos-iso" "$arch" "${old_digest##*:}" "${new_sha256:0:12}..."
      data=$(printf '%s\n' "$data" | jq --arg a "$arch" --arg u "$resolved_url" --arg d "$new_digest" '
        .vm-setup.nixos-iso[$a] = {url: $u, digest: $d}
      ')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.vm-setup.nixos-iso // {}) | keys[]')
fi

# ---------------------------------------------------------------------------
# tart-images — Query GHCR OCI registry for Cirrus CI macOS base image digests
# ---------------------------------------------------------------------------
if section_enabled vm-setup || section_enabled tart-images; then
  while IFS= read -r os_version; do
    [ -z "$os_version" ] && continue
    entry=$(printf '%s\n' "$data" | jq -c --arg v "$os_version" '(.vm-setup.tart-images // {})[$v] // empty')
    [ -z "$entry" ] && continue

    old_image=$(printf '%s\n' "$entry" | jq -r '.image // empty')
    old_digest=$(printf '%s\n' "$entry" | jq -r '.digest // empty')
    [ -z "$old_image" ] && continue

    # Pull the OCI image name from the lockfile entry; extract the short repo name from the full image path
    image_repo="${old_image#ghcr.io/}"
    if [ -z "$image_repo" ]; then
      printf 'bump-lockfile: warning: no image repo found for %s, skipping\n' "$os_version" >&2
      continue
    fi

    # Get an anonymous GHCR token and query the manifest
    ghcr_token=$(curl -s "https://ghcr.io/token?service=ghcr.io\&scope=repository:${image_repo}:pull" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -z "$ghcr_token" ]; then
      printf 'bump-lockfile: warning: could not get GHCR token for %s, skipping\n' "$old_image" >&2
      continue
    fi

    new_digest=$(curl -sL -D - -o /dev/null \
      -H "Authorization: Bearer $ghcr_token" \
      -H "Accept: application/vnd.oci.image.index.v1+json" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${image_repo}/manifests/latest" 2>/dev/null | grep -i "^docker-content-digest:" | grep -oE 'sha256:[a-f0-9]{64}' || true)

    if [ -z "$new_digest" ]; then
      printf 'bump-lockfile: warning: could not fetch digest for %s, skipping\n' "$old_image" >&2
      continue
    fi

    if [ "$old_digest" != "$new_digest" ]; then
      log_update "vm-setup.tart-images" "$os_version" "${old_digest:0:20}..." "${new_digest:0:20}..."
      data=$(printf '%s\n' "$data" | jq --arg v "$os_version" --arg d "$new_digest" '
        .vm-setup.tart-images[$v].digest = $d
      ')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.vm-setup.tart-images // {}) | keys[]')
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
