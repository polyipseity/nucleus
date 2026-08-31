#!/usr/bin/env bash
# Updates flake inputs and rewraps all SOPS-managed files for current
# recipients.
#
# WHY no Homebrew stage: nix-homebrew manages taps immutably via flake.lock
# (mutableTaps = false), so brew update / brew upgrade are both impossible
# (read-only Nix store paths) and unnecessary (tap versions are bumped by
# the flake stage; installed packages are reconciled by nix-darwin activation).
#
# Commands: [--flake|--no-flake] [--sops|--no-sops].
# Each stage is independently skippable, so partial updates are possible
# (e.g. rewrap secrets without touching flake.lock).
#
# Environment variables read: NIX_CONFIG (merged into the update invocation),
# NUCLEUS_REPO_ROOT (via derive_repo_root).
#
# Prerequisites: nix with flakes; sops only when its stage is enabled.
# Exits 1 when a selected stage fails — flake errors are reported explicitly,
# and sops failures abort via set -e.

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
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# usage
#   Prints the CLI synopsis and the two stage toggles to stdout.
usage() {
  usage_std "$(basename "$0")" "update|lockfile [options]"
  cat <<'EOF'
  update    Update flake inputs and rewrap SOPS-managed files (default).
  lockfile  Query each available tool for the current version of each pinned
            item and write an updated lockfile atomically.

  update options:
    --flake|--no-flake    Control nix flake update (default: --flake).
    --sops|--no-sops      Control sops updatekeys (default: --sops).

  lockfile options:
    --sections <list>     Comma-separated section names to update (default: all).
    --verify              Check for updates without writing (exit 1 if changes).
    --verify-installed    Verify installed tool versions against the pinned
                          lockfile sections (exit 1 on drift; never writes).
    --list-sections       Print valid section names, one per line.
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# update subcommand — update flake inputs and rewrap SOPS-managed files.
# ──────────────────────────────────────────────────────────────────────────────

do_update() {
  REPO_ROOT="$(derive_repo_root)"

  flake=true
  sops=true

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --flake)
      flake=true
      ;;
    --no-flake)
      flake=false
      ;;

    --sops)
      sops=true
      ;;
    --no-sops)
      sops=false
      ;;

    *)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    esac
    shift
  done

  run_nix() {
    # NIX_PATH is set explicitly because darwin-rebuild's export NIX_PATH=${NIX_PATH:-}
    # would otherwise clear it, overriding the nix-path config option.
    # WHY: --option warn-dirty false keeps dirty-repo warnings out of update
    # output; merge_nix_config preserves any user NIX_CONFIG additions.
    NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" nix --option warn-dirty false "$@"
  }

  # update_flake_inputs
  #   Runs `nix flake update` against the flake at src/. WHY: the flake lock
  #   must live next to flake.nix (Nix requirement), so the update explicitly
  #   targets src/ rather than the repo root.
  update_flake_inputs() {
    # Updates pinned upstream revisions in src/flake.lock.
    if flake_output="$(run_nix flake update --flake "$REPO_ROOT/src" 2>&1)"; then
      if [ -n "$flake_output" ]; then
        printf '%s\n' "$flake_output"
      fi
      return 0
    fi

    printf '%s\n' "$flake_output" >&2

    # Transient network / GitHub API-rate-limit failures should propagate as
    # errors so callers can handle the failure upstream.
    # WHY: these specific signatures are called out so an operator can retry
    # later instead of suspecting the lockfile itself broke.
    if printf '%s' "$flake_output" | grep -Eq 'API rate limit exceeded|unable to download|HTTP error 403'; then
      error "flake update failed due to transient fetch/rate-limit error"
    fi

    error "flake update failed"
  }

  # rewrap_sops_files
  #   Re-encrypts every SOPS-managed repository asset with the recipient set
  #   declared in .sops.yaml. WHY: after machine age/GPG keys are added or
  #   removed, ciphertext is still bound to the old set — new machines could
  #   not decrypt it. updatekeys rewraps in place without touching plaintext.
  rewrap_sops_files() {
    # Rewrap every encrypted repository asset so recipients stay in sync with
    # .sops.yaml key declarations after machine additions/removals.
    sops_config="$REPO_ROOT/.sops.yaml"

    for encrypted_file in \
      "$REPO_ROOT"/src/secrets/users/*.yml; do
      if [ -f "$encrypted_file" ]; then
        sops --config "$sops_config" updatekeys --yes "$encrypted_file"
      fi
    done

    # WHY: overlay wallpapers are encrypted too (src/users/*/wallpapers/encrypted/*.sops)
    # and would otherwise rot against the updated recipient set.
    _update_wallpaper_list="$(mktemp)"
    find "$REPO_ROOT/src/users" -path '*/wallpapers/encrypted/*.sops' -type f >"$_update_wallpaper_list"
    while IFS= read -r encrypted_wallpaper; do
      if [ -f "$encrypted_wallpaper" ]; then
        sops --config "$sops_config" updatekeys --yes "$encrypted_wallpaper"
      fi
    done <"$_update_wallpaper_list"
    rm -f "$_update_wallpaper_list"
  }

  if [ "$flake" = true ]; then
    update_flake_inputs
  fi

  if [ "$sops" = true ]; then
    rewrap_sops_files
  fi

  nuc_done "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# lockfile subcommand — query each available tool for the current version of
# each pinned item and write an updated lockfile atomically. Inlined from
# scripts/bump-lockfile.sh.
# ──────────────────────────────────────────────────────────────────────────────

do_lockfile() {
  # shellcheck source=../src/scripts/checks/lockfile-enforcement-lib.sh
  . "$SCRIPT_DIR/../src/scripts/checks/lockfile-enforcement-lib.sh"

  usage_lockfile() {
    usage_std "$(basename "$0") lockfile" "[--sections <comma-separated>] [--verify] [--verify-installed] [--list-sections]" \
      "Query each available tool for the current version of each pinned item and write an updated lockfile atomically."
    cat <<'EOF'

Options:
  --sections <list>  Comma-separated section names to update (default: all)
  --verify           Check for updates without writing (exit 1 if changes would be made)
  --verify-installed  Verify installed tool versions against the pinned lockfile
                      sections (exit 1 on drift; never writes)
  --list-sections    Print valid section names, one per line
  --help             Show this usage
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

  # Canonical section names (alphabetical). cargo aliases cargo-binstall; the
  # legacy bare tokens nixos-iso / tart-images normalize to vm-setup children.
  _VALID_SECTIONS_CSV="bun,cargo,cargo-binstall,pwsh,rustup,scoop,source-builds,superpowers,uv,version,vm-setup,vm-setup.nixos-iso,vm-setup.tart-images,winget,suggestions.cursor,suggestions.homebrew,suggestions.homebrew.masApps,suggestions.ollama,suggestions.opencode,suggestions.vscode,suggestions.vm-setup.windows"

  # Parse flags (comma-separated, defaults to all)
  SECTIONS=""
  VERIFY=false
  VERIFY_INSTALLED=false

  while [ $# -gt 0 ]; do
    case "$1" in
    --help)
      usage_lockfile
      exit 0
      ;;
    --list-sections)
      IFS=',' read -ra _sections <<<"$_VALID_SECTIONS_CSV"
      printf '%s\n' "${_sections[@]}"
      exit 0
      ;;
    --sections)
      shift
      SECTIONS="$1"
      ;;
    --verify)
      VERIFY=true
      ;;
    --verify-installed)
      VERIFY_INSTALLED=true
      ;;
    *)
      error "unknown flag: $1"
      exit 1
      ;;
    esac
    shift
  done

  # Validate and normalize --sections tokens: trim whitespace, map legacy bare
  # sub-section names (nixos-iso, tart-images) and the cargo alias to canonical
  # dotted form, and reject anything unknown.
  _is_valid_section() {
    local token="$1"
    case ",$_VALID_SECTIONS_CSV," in
    *",$token,"*) return 0 ;;
    esac
    return 1
  }

  if [ -n "$SECTIONS" ]; then
    _normalized=()
    IFS=',' read -ra _tokens <<<"$SECTIONS"
    for _tok in "${_tokens[@]}"; do
      _tok="$(printf '%s\n' "$_tok" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -z "$_tok" ] && continue
      case "$_tok" in
      nixos-iso) _tok="vm-setup.nixos-iso" ;;
      tart-images) _tok="vm-setup.tart-images" ;;
      cargo) _tok="cargo-binstall" ;;
      esac
      if ! _is_valid_section "$_tok"; then
        error "unknown section '$_tok' (valid: $_VALID_SECTIONS_CSV)"
        exit 1
      fi
      _normalized+=("$_tok")
    done
    SECTIONS="$(printf '%s,' "${_normalized[@]}")"
    SECTIONS="${SECTIONS%,}"
  fi

  # Explicitly-selected sections without an updater are kept manual; warn so the
  # run does not silently skip them. Parent tokens (homebrew, vm-setup) do not
  # warn for their no-updater children.
  if [ -n "$SECTIONS" ]; then
    IFS=',' read -ra _tokens <<<"$SECTIONS"
    for _tok in "${_tokens[@]}"; do
      if [[ ",source-builds,superpowers,suggestions.homebrew.masApps,suggestions.opencode,suggestions.vm-setup.windows,version," == *",$_tok,"* ]]; then
        warn "section '$_tok' has no updater — kept manual"
      fi
    done
  fi

  section_enabled() {
    local name="$1"
    [ -z "$SECTIONS" ] && return 0 # no filter = all enabled
    local token
    IFS=',' read -ra _tokens <<<"$SECTIONS"
    for token in "${_tokens[@]}"; do
      if [ "$token" = "$name" ] || [[ "$name" == "$token".* ]] || [[ "$token" == "$name".* ]]; then
        return 0
      fi
    done
    return 1
  }

  # suggestions_enabled mirrors section_enabled but for the suggestions.* subtree.
  suggestions_enabled() {
    local name="$1"
    [ -z "$SECTIONS" ] && return 0 # no filter = all enabled
    local token
    IFS=',' read -ra _tokens <<<"$SECTIONS"
    for token in "${_tokens[@]}"; do
      if [[ "$token" == suggestions* ]]; then
        if [ "$token" = "suggestions" ] || [[ "$name" == "$token".* ]] || [[ "$token" == "$name".* ]]; then
          return 0
        fi
      fi
    done
    return 1
  }

  # Helpers
  changed=false
  log_update() {
    say "updating $1.$2 from $3 to $4"
    changed=true
  }

  # Read lockfile
  data=$(cat "$LOCKFILE_ABS")

  # --verify-installed: verify installed tool versions against the pinned
  # lockfile sections and exit (never writes). Delegates to the shared probe
  # library used by the check step so behavior stays identical.
  if $VERIFY_INSTALLED; then
    verify_installed_versions "$REPO_ROOT"
    exit $?
  fi

  # winget — winget show --id <id>
  if section_enabled winget; then
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
      warn "winget: command not found — skipping section"
    fi
  fi

  # scoop — scoop info <pkg>
  if section_enabled scoop; then
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
      warn "scoop: command not found — skipping section"
    fi
  fi

  # cargo-binstall — crates.io API (alias: cargo)
  if section_enabled cargo-binstall; then
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      if printf '%s\n' "$data" | jq -e --arg k "$key" '(.["cargo-binstall"][$k] | type) == "object"' >/dev/null; then
        continue # VCS hash-pin entry — no crates.io query can update the rev
      fi
      old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.["cargo-binstall"] // {})[$k] // empty')
      [ -z "$old" ] && continue

      # Query crates.io for the latest stable version (User-Agent required;
      # crates.io returns 403 without it), falling back to cargo search.
      # check-suppress:suppression_doc: crates.io API may be unreachable or return a non-JSON error page; the cargo search fallback handles failure.
      new=$(curl -fsSL -A "nucleus-bump-lockfile" "https://crates.io/api/v1/crates/$key" 2>/dev/null | jq -r '.crate.max_stable_version // .versions[0].num // empty' 2>/dev/null) || new=""
      if [ -z "$new" ]; then
        # check-suppress:suppression_doc: cargo may be unavailable or the crate unpublished; the warn path reports the failure.
        new=$(cargo search --limit 1 "$key" 2>/dev/null | awk -v k="$key" -F' = ' '$1 == k {gsub(/"/, "", $2); sub(/[[:space:]].*/, "", $2); print $2; exit}') || new=""
      fi
      if [ -z "$new" ]; then
        warn "cargo-binstall.$key: no version source (crates.io API and cargo search both failed)"
        continue
      fi
      if [ "$new" != "$old" ]; then
        log_update "cargo-binstall" "$key" "$old" "$new"
        data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.["cargo-binstall"][$k] = $v')
      fi
    done < <(printf '%s\n' "$data" | jq -r '(.["cargo-binstall"] // {}) | keys[]')
  fi

  # bun — npm registry API (curl)
  if section_enabled bun; then
    if command -v curl >/dev/null 2>&1; then
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.bun // {})[$k] // empty')
        [ -z "$old" ] && continue
        new=$(curl -fsSL "https://registry.npmjs.org/$key/latest" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
          log_update "bun" "$key" "$old" "$new"
          data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.bun[$k] = $v')
        fi
      done < <(printf '%s\n' "$data" | jq -r '(.bun // {}) | keys[]')
    else
      warn "curl: command not found — skipping bun section"
    fi
  fi

  # uv — uv tool list
  if section_enabled uv; then
    declare -A uv_installed=()
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
      -*) continue ;;
      esac
      pkg="${line%% *}"
      rest="${line#* }"
      if echo "$rest" | grep -q '@'; then
        ver="${rest#*@}"
      else
        ver="${rest#v}"
      fi
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
      if rustup toolchain list 2>/dev/null | grep -q "^$key"; then
        if [ "$key" = "nightly" ] || printf '%s\n' "$key" | grep -qE '^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
          new=$(rustc "+$key" --version 2>/dev/null | grep -oE 'nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
        else
          new=$(rustc "+$key" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
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

  # cursor — cursor --list-extensions --show-versions
  if suggestions_enabled suggestions.cursor; then
    cursor_output=""
    if command -v cursor >/dev/null 2>&1; then
      # check-suppress:suppression_doc: Cursor CLI may not be installed; empty extension list is expected.
      cursor_output=$(cursor --list-extensions --show-versions 2>/dev/null || true)
    fi

    if [ -n "$cursor_output" ]; then
      declare -A cursor_exts=()
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
        *@*)
          pkg="${line%%@*}"
          ver="${line#*@}"
          [ -n "$pkg" ] && [ -n "$ver" ] && cursor_exts["$pkg"]="$ver"
          ;;
        esac
      done <<<"$cursor_output"

      while IFS= read -r key; do
        [ -z "$key" ] && continue
        old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.suggestions.cursor // {})[$k] // empty')
        [ -z "$old" ] && continue
        new="${cursor_exts[$key]:-}"
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
          log_update "suggestions.cursor" "$key" "$old" "$new"
          data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.suggestions.cursor[$k] = $v')
        fi
      done < <(printf '%s\n' "$data" | jq -r '(.suggestions.cursor // {}) | keys[]')
    fi
  fi

  # vscode — code/code-insiders --list-extensions --show-versions
  if suggestions_enabled suggestions.vscode; then
    vscode_output=""
    if command -v code >/dev/null 2>&1; then
      # check-suppress:suppression_doc: VS Code CLI may not be installed; empty extension list is expected.
      vscode_output=$(code --list-extensions --show-versions 2>/dev/null || true)
    elif command -v code-insiders >/dev/null 2>&1; then
      # check-suppress:suppression_doc: VS Code CLI may not be installed; empty extension list is expected.
      vscode_output=$(code-insiders --list-extensions --show-versions 2>/dev/null || true)
    fi

    if [ -n "$vscode_output" ]; then
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
        old=$(printf '%s\n' "$data" | jq -r --arg k "$key" '(.suggestions.vscode // {})[$k] // empty')
        [ -z "$old" ] && continue
        new="${vscode_exts[$key]:-}"
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
          log_update "suggestions.vscode" "$key" "$old" "$new"
          data=$(printf '%s\n' "$data" | jq --arg k "$key" --arg v "$new" '.suggestions.vscode[$k] = $v')
        fi
      done < <(printf '%s\n' "$data" | jq -r '(.suggestions.vscode // {}) | keys[]')
    fi
  fi

  : "${NUCLEUS_OLLAMA_HOST:=$(jq -r '.ollama.network.default | "\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo "127.0.0.1:11434")}"
  if suggestions_enabled suggestions.ollama; then
    while IFS= read -r host; do
      [ -z "$host" ] && continue
      model_count=$(printf '%s\n' "$data" | jq -r --arg h "$host" '(.suggestions.ollama[$h] // []) | length')
      [ "$model_count" -eq 0 ] && continue

      for idx in $(seq 0 $((model_count - 1))); do
        entry=$(printf '%s\n' "$data" | jq -c --arg h "$host" --argjson i "$idx" '(.suggestions.ollama[$h] // [])[$i]')
        [ -z "$entry" ] && continue

        name=$(printf '%s\n' "$entry" | jq -r '.name // empty')
        tag=$(printf '%s\n' "$entry" | jq -r '.tag // empty')
        [ -z "$name" ] || [ -z "$tag" ] && continue

        old_digest=$(printf '%s\n' "$entry" | jq -r '.digest // empty')

        # check-suppress:suppression_doc: model may not be pulled yet; info probe expected to fail.
        ollama_info=$(OLLAMA_HOST="$NUCLEUS_OLLAMA_HOST" ollama show "$name:$tag" --format json 2>/dev/null || true)
        if [ -n "$ollama_info" ]; then
          new_digest=$(printf '%s\n' "$ollama_info" | jq -r '.digest // empty' 2>/dev/null || true) # check-suppress:suppression_doc: jq may error on empty/malformed input from failed ollama probe; null check downstream handles the empty case.
          if [ -n "$new_digest" ] && [ "$new_digest" != "$old_digest" ]; then
            log_update "suggestions.ollama ($host)" "$name:$tag" "${old_digest:-none}" "$new_digest"
            data=$(printf '%s\n' "$data" | jq --arg h "$host" --arg n "$name" --arg t "$tag" --arg d "$new_digest" '
              .suggestions.ollama[$h] |= map(
                if .name == $n and .tag == $t then
                  .digest = $d
                else
                  .
                end
              )
            ')
          fi
        fi
      done
    done < <(printf '%s\n' "$data" | jq -r '(.suggestions.ollama // {}) | keys[]')
  fi

  # nixos-iso — Query NixOS channel for latest ISO URL and its SHA-256
  if section_enabled vm-setup.nixos-iso; then
    while IFS= read -r arch; do
      [ -z "$arch" ] && continue
      old_url=$(printf '%s\n' "$data" | jq -r --arg a "$arch" '(.["vm-setup"]["nixos-iso"] // {})[$a].url // empty')
      old_digest=$(printf '%s\n' "$data" | jq -r --arg a "$arch" '(.["vm-setup"]["nixos-iso"] // {})[$a].digest // empty')
      [ -z "$old_url" ] && continue

      latest_url="https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-${arch}.iso"
      resolved_url=$(curl -sIL "$latest_url" 2>/dev/null | grep -i "^location:" | tail -1 | tr -d '[:space:]' | sed 's/^location://I')
      if [ -z "$resolved_url" ]; then
        warn "could not resolve $latest_url for $arch"
        continue
      fi

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
          .["vm-setup"]["nixos-iso"][$a] = {url: $u, digest: $d}
        ')
      fi
    done < <(printf '%s\n' "$data" | jq -r '(.["vm-setup"]["nixos-iso"] // {}) | keys[]')
  fi

  # tart-images — Query GHCR OCI registry for Cirrus CI macOS base image digests
  if section_enabled vm-setup.tart-images; then
    while IFS= read -r os_version; do
      [ -z "$os_version" ] && continue
      entry=$(printf '%s\n' "$data" | jq -c --arg v "$os_version" '(.["vm-setup"]["tart-images"] // {})[$v] // empty')
      [ -z "$entry" ] && continue

      old_image=$(printf '%s\n' "$entry" | jq -r '.image // empty')
      old_digest=$(printf '%s\n' "$entry" | jq -r '.digest // empty')
      [ -z "$old_image" ] && continue

      image_repo="${old_image#ghcr.io/}"
      if [ -z "$image_repo" ]; then
        warn "no image repo found for $os_version, skipping"
        continue
      fi

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
          .["vm-setup"]["tart-images"][$v].digest = $d
        ')
      fi
    done < <(printf '%s\n' "$data" | jq -r '(.["vm-setup"]["tart-images"] // {}) | keys[]')
  fi

  # Compute the diff for --verify mode
  if $VERIFY; then
    _data_sorted=$(printf '%s\n' "$data" | jq -S .)
    # check-suppress:suppression_doc: diff exits 1 when files differ; output is needed for the [ -n "$_diff" ] check.
    _diff=$(diff <(printf '%s\n' "$_data_sorted") "$LOCKFILE_ABS" 2>/dev/null || true)
    if [ -n "$_diff" ]; then
      say "lockfile out of date — changes would be made:"
      printf '%s\n' "$_diff"
      exit 1
    fi
    say "lockfile is up to date."
    exit 0
  fi

  # Skip the write when no section produced a change.
  if [ "$changed" != true ]; then
    say "no changes — lockfile up to date"
    exit 0
  fi

  # Stamp the timestamp right before the atomic write. Sort keys recursively
  # (jq -S) so the on-disk file is deterministic and matches the PowerShell
  # writer's ConvertTo-Json ordering.
  data=$(printf '%s\n' "$data" | jq -S --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated = $d')

  # Atomic write
  tmpfile=$(mktemp "$LOCKFILE_ABS.tmp.XXXXXX")
  trap 'rm -f "$tmpfile"' EXIT

  printf '%s\n' "$data" >"$tmpfile"
  mv -- "$tmpfile" "$LOCKFILE_ABS"

  say "wrote $LOCKFILE_REL"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ──────────────────────────────────────────────────────────────────────────────

# WHY: the subcommand word is captured first, then dropped (tolerating its
# absence) so every do_* handler receives only its own remaining options. A
# leading flag (or no word) defaults to the `update` subcommand so legacy
# `nucleus-update [--flake ...]` invocations keep working unchanged.
action="${1:-update}"
case "$action" in
-h | --help | help)
  usage
  exit 0
  ;;
esac

if [ "$action" = "update" ] || [ "$action" = "lockfile" ]; then
  subcommand="$action"
  shift # consume the subcommand word
elif [ "${action#-}" != "$action" ]; then
  subcommand="update"
else
  error "unsupported subcommand '$action'"
  usage >&2
  exit 1
fi

case "$subcommand" in
update) do_update "$@" ;;
lockfile) do_lockfile "$@" ;;
esac
