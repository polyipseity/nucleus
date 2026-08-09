#!/usr/bin/env bash
# Reads src/lockfiles/lockfile.json, queries each available tool for the
# current installed/published version of each pinned item, and writes an
# updated lockfile atomically.
#
# Sections (pass comma-separated via --sections to update selectively):
#   winget        winget show --id <id>
#   scoop         scoop info <pkg>
#   cargo-binstall Keep current version     (no reliable CLI query)
#   bun           npm view <pkg> version
#   uv            uv tool list
#   rustup        rustc +<ch> --version
#   pwsh          Find-Module via pwsh      (skip if pwsh unavailable)
#   vscode        code/code-insiders --list-extensions --show-versions
#                 (skip if neither available)
#   ollama        ollama show <name>:<tag> --format json
#                 (skip if ollama unavailable)
#   vm-setup      VM image artifact pins (nixos-iso, tart-images, windows). Use --sections nixos-iso etc. for sub-sections.

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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[--sections <comma-separated>] [--verify]" \
    "Query each available tool for the current version of each pinned item and write an updated lockfile atomically."
  cat <<'EOF'

Sections (pass comma-separated via --sections to update selectively):
  winget        winget show --id <id>
  scoop         scoop info <pkg>
  cargo-binstall Keep current version     (no reliable CLI query)
  bun           npm view <pkg> version
  uv            uv tool list
  rustup        rustc +<ch> --version
  pwsh          Find-Module via pwsh      (skip if pwsh unavailable)
  vscode        code/code-insiders --list-extensions --show-versions
                (skip if neither available)
  ollama        ollama show <name>:<tag> --format json
                (skip if ollama unavailable)
  vm-setup      VM image artifact pins (nixos-iso, tart-images, windows). Use --sections nixos-iso etc. for sub-sections.
EOF
}

REPO_ROOT="$(derive_repo_root)"
LOCKFILE_REL="src/lockfiles/lockfile.json"
LOCKFILE_ABS="$REPO_ROOT/$LOCKFILE_REL"

# Pre-flight checks
require_command jq

if [ ! -f "$LOCKFILE_ABS" ]; then
  error "lockfile not found at $LOCKFILE_ABS"
  exit 1
fi

# Parse --sections flag (comma-separated, defaults to all)
SECTIONS=""
VERIFY=false

while [ $# -gt 0 ]; do
  case "$1" in
  --sections)
    shift
    SECTIONS="$1"
    ;;
  --verify)
    VERIFY=true
    ;;
  --help)
    usage
    exit 0
    ;;
  *)
    error "unknown flag: $1"
    exit 1
    ;;
  esac
  shift
done

section_enabled() {
  local name="$1"
  [ -z "$SECTIONS" ] && return 0 # no filter = all enabled
  case ",$SECTIONS," in
  *",$name,"*) return 0 ;;
  *) return 1 ;;
  esac
}

# Helpers
log_update() {
  say "updating $1.$2 from $3 to $4"
}

# Read lockfile
data=$(cat "$LOCKFILE_ABS")

# Update timestamp to current UTC ISO 8601
data=$(printf '%s\n' "$data" | jq --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated = $d')

# winget — winget show --id <id>
if section_enabled winget; then
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
fi

# scoop — scoop info <pkg>
if section_enabled scoop; then
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
fi

# cargo-binstall — keep current version (no reliable CLI query)
#   No CLI query available; pinned versions are kept as-is.

# bun — npm view <pkg> version
if section_enabled bun; then
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
fi

# uv — uv tool list
if section_enabled uv; then
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
    # check-suppress:suppression_doc: uv may not be installed yet; empty tool list is expected.
  done < <(uv tool list 2>/dev/null || true)

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if printf '%s\n' "$data" | jq -e --arg k "$key" '(.uv[$k] | type) == "object"' >/dev/null; then
      continue # VCS hash-pin entry — no CLI query can update the rev
    fi
    old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.uv // {})[$k] // empty')
    [ -z "$old" ] && continue
    new="${uv_installed[$key]:-}"
    if [ -n "$new" ] && [ "$new" != "$old" ]; then
      log_update "uv" "$key" "$old" "$new"
      data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.uv[$k] = $v')
    fi
  done < <(printf '%s\n' "$data" | jq -r '(.uv // {}) | keys[]')
fi

# rustup — rustc +<ch> --version
if section_enabled rustup; then
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
fi

# pwsh — Find-Module via pwsh -NoProfile
if section_enabled pwsh; then
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
fi

# homebrew — brew list --versions, brew list --cask --versions
if section_enabled homebrew; then
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
fi

# vscode — code/code-insiders --list-extensions --show-versions
if section_enabled vscode; then
  vscode_output=""
  if command -v code >/dev/null 2>&1; then
    # check-suppress:suppression_doc: VS Code CLI may not be installed; empty extension list is expected.
    vscode_output=$(code --list-extensions --show-versions 2>/dev/null || true)
  elif command -v code-insiders >/dev/null 2>&1; then
    # check-suppress:suppression_doc: VS Code CLI may not be installed; empty extension list is expected.
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
    done <<<"$vscode_output"

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
  fi
fi

: "${NUCLEUS_OLLAMA_HOST:=$(jq -r '.ollama.network.default | "\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo "127.0.0.1:11434")}"
if section_enabled ollama; then
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
      # check-suppress:suppression_doc: model may not be pulled yet; info probe expected to fail.
      ollama_info=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama show "$name:$tag" --format json 2>/dev/null || true)
      if [ -n "$ollama_info" ]; then
        new_digest=$(printf '%s\n' "$ollama_info" | jq -r '.digest // empty' 2>/dev/null || true) # check-suppress:suppression_doc: jq may error on empty/malformed input from failed ollama probe; null check downstream handles the empty case.
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
fi

# nixos-iso — Query NixOS channel for latest ISO URL and its SHA-256
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
      warn "could not resolve $latest_url for $arch"
      continue
    fi

    # Fetch the SHA-256 checksum from the .sha256 sidecar
    sha256_url="${resolved_url}.sha256"
    sha256_content=$(curl -sL "$sha256_url")
    new_sha256=$(printf '%s\n' "$sha256_content" | grep -oE '^[0-9a-f]{64}' | head -1)
    if [ -z "$new_sha256" ]; then
      warn "could not fetch checksum for $arch ($sha256_url)"
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

# tart-images — Query GHCR OCI registry for Cirrus CI macOS base image digests
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
      warn "no image repo found for $os_version, skipping"
      continue
    fi

    # Get an anonymous GHCR token and query the manifest
    # check-suppress:suppression_doc: network/registry may not be reachable; [ -z ] guard handles failure.
    ghcr_token=$(curl -s "https://ghcr.io/token?service=ghcr.io\&scope=repository:${image_repo}:pull" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -z "$ghcr_token" ]; then
      warn "could not get GHCR token for $old_image, skipping"
      continue
    fi

    new_digest=$(curl -sL -D - -o /dev/null \
      -H "Authorization: Bearer $ghcr_token" \
      -H "Accept: application/vnd.oci.image.index.v1+json" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${image_repo}/manifests/latest" 2>/dev/null | grep -i "^docker-content-digest:" | grep -oE 'sha256:[a-f0-9]{64}' || true) # check-suppress:suppression_doc: network/registry may not be reachable; [ -z ] guard handles failure.

    if [ -z "$new_digest" ]; then
      warn "could not fetch digest for $old_image, skipping"
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

# Compute the diff for --verify mode
if $VERIFY; then
  # check-suppress:suppression_doc: diff exits 1 when files differ; output is needed for the [ -n "$_diff" ] check.
  _diff=$(diff <(printf '%s\n' "$data") "$LOCKFILE_ABS" 2>/dev/null || true)
  if [ -n "$_diff" ]; then
    say "lockfile out of date — changes would be made:"
    printf '%s\n' "$_diff"
    exit 1
  fi
  say "lockfile is up to date."
  exit 0
fi

# Atomic write
tmpfile=$(mktemp "$LOCKFILE_ABS.tmp.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

printf '%s\n' "$data" >"$tmpfile"
mv -- "$tmpfile" "$LOCKFILE_ABS"

say "wrote $LOCKFILE_REL"
