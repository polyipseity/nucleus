#!/usr/bin/env bash
# gc.sh — Perform bounded garbage collection on POSIX hosts.
#
# Expires old Home Manager generations, runs nix store GC, removes stale
# decrypted wallpapers, gc's tool caches, and removes locally installed
# Ollama models absent from the manifest.
#
# Arguments:
#   --tool-cache-gc|--no-tool-cache-gc  Control bun/cargo/rustc/uv cache gc (default: --tool-cache-gc).
#   --hm-gc|--no-hm-gc                        Control home-manager generation expiration (default: --hm-gc).
#   --nix-gc|--no-nix-gc                      Control nix-collect-garbage (default: --nix-gc).
#   --ollama-gc|--no-ollama-gc          Control stale Ollama model removal (default: --ollama-gc).
#   --wallpaper-gc|--no-wallpaper-gc    Control stale wallpaper gc (default: --wallpaper-gc).
#   --vm-gc|--no-vm-gc                  Control stale VM artifact removal (default: --vm-gc).
#   --expiry <duration>                       Master expiry override (e.g. "14d", "30d"). Per-tool flags win.
#   --hm-expiry <duration>                    Home Manager generation expiry duration in nix format (e.g. "7d").
#   --nix-expiry <duration>                   Nix store GC --delete-older-than duration (e.g. "7d", "30d").
#   --dry-run|--no-dry-run                    Print actions without executing (default: --no-dry-run).
#
# Environment variables:
#   NUCLEUS_GC_EXPIRY        Master expiry override (same as --expiry).
#   NUCLEUS_GC_HM_EXPIRY     HM expiry override (same as --hm-expiry).
#   NUCLEUS_GC_NIX_EXPIRY    Nix expiry override (same as --nix-expiry).
#
# Exit conditions:
#   0 on success; non-zero on failure.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  --tool-cache-gc|--no-tool-cache-gc  Control bun/cargo/rustc/uv cache gc (default: --tool-cache-gc).
  --hm-gc|--no-hm-gc                        Control home-manager generation expiration (default: --hm-gc).
  --nix-gc|--no-nix-gc                      Control nix-collect-garbage (default: --nix-gc).
  --ollama-gc|--no-ollama-gc          Control stale Ollama model removal (default: --ollama-gc).
  --wallpaper-gc|--no-wallpaper-gc    Control stale wallpaper gc (default: --wallpaper-gc).
  --vm-gc|--no-vm-gc                  Control stale VM artifact removal (default: --vm-gc).
  --expiry <duration>                       Master expiry override (e.g. "14d"). Per-tool flags win (default: "7d").
  --hm-expiry <duration>                    Home Manager generation expiry duration in nix format (e.g. "7d").
  --nix-expiry <duration>                   Nix store GC --delete-older-than duration (e.g. "7d", "30d").
  --dry-run|--no-dry-run                    Print actions without executing (default: --no-dry-run).
EOF
}

REPO_ROOT="$(resolve_nucleus_root)"

tool_cache_gc=true
hm_gc=true
nix_gc=true
ollama_gc=true
wallpaper_gc=true
vm_gc=true
dry_run=false
hm_expiry_arg=""
nix_expiry_arg=""
expiry_arg=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --tool-cache-gc)
      tool_cache_gc=true
      ;;
    --no-tool-cache-gc)
      tool_cache_gc=false
      ;;
    --hm-gc)
      hm_gc=true
      ;;
    --no-hm-gc)
      hm_gc=false
      ;;
    --nix-gc)
      nix_gc=true
      ;;
    --no-nix-gc)
      nix_gc=false
      ;;
    --ollama-gc)
      ollama_gc=true
      ;;
    --no-ollama-gc)
      ollama_gc=false
      ;;
    --wallpaper-gc)
      wallpaper_gc=true
      ;;
    --no-wallpaper-gc)
      wallpaper_gc=false
      ;;
    --vm-gc)
      vm_gc=true
      ;;
    --no-vm-gc)
      vm_gc=false
      ;;
    --expiry)
      expiry_arg="$2"
      shift
      ;;
    --hm-expiry)
      hm_expiry_arg="$2"
      shift
      ;;
    --nix-expiry)
      nix_expiry_arg="$2"
      shift
      ;;
    --dry-run)
      dry_run=true
      ;;
    --no-dry-run)
      dry_run=false
      ;;
    *)
      printf '%s\n' "gc: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

nix_expiry_to_hm() {
  # Convert nix duration format to date format compatible with
  # home-manager expire-generations.
  #   "7d"  → "-7 days"
  #   "14d" → "-14 days"
  #   "4w"  → "-4 weeks"
  local input="$1"
  local num="${input%[a-zA-Z]*}"
  local unit="${input##*[0-9]}"
  case "$unit" in
    d) printf '%s\n' "-${num} days" ;;
    w) printf '%s\n' "-${num} weeks" ;;
    *) printf '%s\n' "-${input}" ;;
  esac
}

# Resolve expiry values with precedence: CLI flag > per-tool env > master flag > master env > default (7d).
hm_expiry="${hm_expiry_arg:-${NUCLEUS_GC_HM_EXPIRY:-${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}}}"
nix_expiry="${nix_expiry_arg:-${NUCLEUS_GC_NIX_EXPIRY:-${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}}}"
hm_expiry_hm_format="$(nix_expiry_to_hm "$hm_expiry")"

expire_hm_generations_if_available() {
  # Home Manager generations are GC roots: nix-collect-garbage cannot reclaim
  # store paths still referenced by live generations.  Expiring generations
  # before running Nix store GC releases those roots so the subsequent
  # collection can reclaim more.  The expiry window is controlled by
  # --hm-expiry / $hm_expiry.
  # Best-effort: hosts without a managed Home Manager profile will not have
  # home-manager in PATH.
  if ! command -v home-manager >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: home-manager unavailable; skipping generation expiry"
    return 0
  fi

  home-manager expire-generations "$hm_expiry_hm_format"
}

run_nix_gc_if_available() {
  # Store gc is best-effort because this helper also runs on hosts where
  # Nix may not be installed (for example minimal CI images).
  if ! command -v nix-collect-garbage >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: nix-collect-garbage unavailable; skipping Nix GC"
    return 0
  fi

  # Expiry controlled by --nix-expiry / $nix_expiry.
  nix-collect-garbage --delete-older-than "$nix_expiry"
}

gc_stale_wallpapers() {
  # Keep the decrypted wallpaper output directory in sync with declarative
  # sources so stale files do not accumulate across apply cycles.
  current_user="${USER:-$(id -un)}"
  assets_dir="$REPO_ROOT/src/assets/wallpapers/$current_user"
  output_dir="$HOME/Pictures/wallpapers"

  if [ ! -d "$assets_dir" ] || [ ! -d "$output_dir" ]; then
    return 0
  fi

  for candidate in "$output_dir"/*; do
    if [ ! -f "$candidate" ]; then
      continue
    fi

    candidate_name=$(basename "$candidate")
    case "$candidate_name" in
      *.xml)
        continue
        ;;
    esac

    if [ ! -e "$assets_dir/$candidate_name.sops" ]; then
      if ! rm -f "$candidate" 2>/dev/null; then
        # Non-fatal: some files under ~/Pictures may be protected by Finder
        # metadata/ACL flags (for example iCloud-managed placeholders). GC
        # should continue pruning other files even if one deletion is denied.
        printf '%s\n' "gc: warning: failed to remove stale wallpaper '$candidate'" >&2
      fi
    fi
  done
}

gc_dir_contents_if_present() {
  # Clears the contents of a cache directory while preserving the directory
  # itself so future tool invocations do not have to recreate parent paths.
  # Args:
  #   $1 — cache directory path
  #   $2 — human-readable label for logs
  cache_dir="$1"
  cache_label="$2"

  if [ ! -d "$cache_dir" ]; then
    return 0
  fi

  if ! find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
    printf '%s\n' "gc: warning: failed to gc $cache_label at '$cache_dir'" >&2
  fi
}

gc_tool_caches_if_available() {
  # bun/cargo/rustc/uv all accumulate user-scoped caches under HOME, regardless
  # of whether the binary came from the system profile or a direnv-loaded
  # devShell.  Clearing those shared cache locations reclaims space for both
  # system and devShell use without touching project-managed dependencies.
  # rustc has no standalone cache tree; its heavy artifacts live in cargo and
  # rustup-managed directories, which are gc'd below.

  cargo_home_dir="${CARGO_HOME:-$HOME/.cargo}"
  rustup_home_dir="${RUSTUP_HOME:-$HOME/.rustup}"
  if [ "$(uname -s)" = "Darwin" ]; then
    platform_cache_root="$HOME/Library/Caches"
  else
    platform_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
  fi

  bun_cache_dir="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
  uv_cache_dir="$platform_cache_root/uv"
  cargo_binstall_cache_dir="$platform_cache_root/cargo-binstall"
  rustup_tmp_dir="$rustup_home_dir/tmp"
  repo_direnv_dir="$REPO_ROOT/.direnv"

  gc_dir_contents_if_present "$bun_cache_dir" "bun install cache"
  gc_dir_contents_if_present "$cargo_binstall_cache_dir" "cargo-binstall cache"
  gc_dir_contents_if_present "$rustup_tmp_dir" "rustup temporary cache"

  # cargo-cache (github.com/matthiaskrgr/cargo-cache) reclaims space from
  # ~/.cargo/registry, ~/.cargo/git, and advisory-db clones.  This remains the
  # authoritative gc path when the binary is available.
  if ! command -v cargo-cache >/dev/null 2>&1; then
    printf '%s\n' "gc: cargo-cache unavailable; skipping cargo cache gc"
  elif [ ! -d "$cargo_home_dir" ]; then
    printf '%s\n' "gc: cargo cache directory '$cargo_home_dir' is missing; skipping cargo cache gc"
  elif ! cargo-cache -r all; then
    printf '%s\n' "gc: warning: cargo-cache gc failed; continuing GC workflow" >&2
  fi

  gc_dir_contents_if_present "$uv_cache_dir" "uv cache"

  # direnv materializes the current repository's nix devShell under .direnv.
  # Clearing only the nucleus checkout keeps scope bounded to managed content;
  # unrelated repositories are left untouched.
  if [ -d "$repo_direnv_dir" ]; then
    if ! rm -rf "$repo_direnv_dir"; then
      printf '%s\n' "gc: warning: failed to remove repo-local direnv cache '$repo_direnv_dir'" >&2
    fi
  fi
}

gc_ollama_models_if_available() {
  # Remove locally installed Ollama models that are absent from the declarative
  # manifest at src/modules/ai/models.json.  Delegates to ai-sync.sh with
  # --gc-only so no new pulls are attempted during GC — a GC run should only
  # reclaim space, not trigger multi-GB model downloads.
  #
  # The probe below checks for both ollama and jq before delegating; ai-sync.sh
  # performs the same checks internally but printing a single skip message here
  # avoids noise from two separate absence warnings.
  if ! command -v ollama >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign before Ollama
    # has been provisioned on this host.
    printf '%s\n' "gc: ollama unavailable; skipping ollama model gc"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # jq is required by ai-sync.sh to parse the JSON manifest.
    printf '%s\n' "gc: jq unavailable; skipping ollama model gc"
    return 0
  fi

  # GC must stay space-reclaim only; do not wait for a cold Ollama daemon to
  # start because that would stall GC on hosts where the AI service is idle.
  NUCLEUS_AI_SYNC_TIMEOUT=0 "$REPO_ROOT/scripts/ai-sync.sh" --gc-only
}

gc_vm_artifacts_if_present() {
  # Remove stale VM artifacts from ~/virtual machines that accumulate across
  # provisioning cycles. This includes temporary Packer build directories and
  # pre-built images for VMs no longer declared in the manifest at
  # src/modules/VMs.json.
  #
  # WHY: VM disk images are large (multi-gigabyte); clearing stale files keeps
  # disk usage bounded and VM provisioning fast.
  if ! command -v jq >/dev/null 2>&1; then
    # jq is required to parse the manifest.
    printf '%s\n' "gc: jq unavailable; skipping VM artifact gc"
    return 0
  fi

  vm_dir="${HOME}/virtual machines"
  images_dir="$vm_dir/images"
  manifest="$REPO_ROOT/src/modules/VMs.json"

  # If VM directories do not exist, there is nothing to clean.
  if [ ! -d "$vm_dir" ]; then
    return 0
  fi

  # If the VM images directory does not exist, there is nothing to clean.
  if [ ! -d "$images_dir" ]; then
    return 0
  fi

  # Load the list of VMs declared in the manifest.
  if [ ! -f "$manifest" ]; then
    printf '%s\n' "gc: manifest '$manifest' not found; skipping VM artifact gc" >&2
    return 1
  fi

  vm_count=$(jq '.VMs | length' "$manifest" 2>/dev/null || printf '%s\n' "0")
  if [ "$vm_count" -eq 0 ]; then
    return 0
  fi

  # Build a list of enabled VM names (disabled VMs are treated as stale).
  declared_names_tmp=$(mktemp)

  if ! jq -r '.VMs[] | select(.enabled == true) | .name' "$manifest" >"$declared_names_tmp" 2>/dev/null; then
    rm -f "$declared_names_tmp"
    printf '%s\n' "gc: failed to parse enabled VM names from '$manifest'; skipping VM artifact gc" >&2
    return 1
  fi

  # Remove temporary Packer build directories.
  for build_dir in "$images_dir"/*-build; do
    if [ -d "$build_dir" ]; then
      if rm -rf "$build_dir" 2>/dev/null; then
        printf '%s\n' "gc: removed temporary VM build directory '$(basename "$build_dir")'"
      else
        printf '%s\n' "gc: warning: failed to remove temporary VM build directory '$build_dir'" >&2
      fi
    fi
  done

  # Remove leftover Packer temporary build directories (dot-prefixed, from interrupted runs).
  if [ -d "$images_dir" ]; then
    for _gc_packer_tmp in "$images_dir"/.??*; do
      [ -d "$_gc_packer_tmp" ] || continue
      printf 'gc: removing stale Packer temporary build directory: %s\n' "${_gc_packer_tmp##*/}" >&2
      rm -rf "$_gc_packer_tmp"
    done
    unset _gc_packer_tmp
  fi

  # Remove stale VM disk images (qcow2) for VMs not declared in the manifest.
  for qcow2_file in "$images_dir"/*.qcow2; do
    if [ -f "$qcow2_file" ]; then
      qcow2_name=$(basename "$qcow2_file" .qcow2)
      if ! grep -Fxq "$qcow2_name" "$declared_names_tmp"; then
        if rm -f "$qcow2_file" 2>/dev/null; then
          printf '%s\n' "gc: removed stale VM disk image '$(basename "$qcow2_file")'"
        else
          printf '%s\n' "gc: warning: failed to remove stale VM disk image '$qcow2_file'" >&2
        fi
      fi
    fi
  done

  # GC stale VM scripts from scripts/ subfolder.
  if [ -d "$vm_dir/scripts" ]; then
    for _gc_script in "$vm_dir"/scripts/*.sh "$vm_dir"/scripts/*.ps1; do
      [ -f "$_gc_script" ] || continue
      _gc_base="$(basename "$_gc_script")"
      _gc_is_declared=false
      while IFS= read -r _gc_declared; do
        case "$_gc_base" in
          *-"$_gc_declared".sh|*-"$_gc_declared".ps1)
            _gc_is_declared=true
            break
            ;;
        esac
      done < "$declared_names_tmp"
      if ! $_gc_is_declared; then
        printf '%s\n' "gc: removed stale VM script '$_gc_base'"
        rm -f "$_gc_script"
      fi
    done
    unset _gc_script _gc_base _gc_is_declared _gc_declared
  fi

  rm -f "$declared_names_tmp"
}

# Step 1: expire HM generations before Nix store GC so the store can reclaim
# paths that were previously held alive as generation GC roots.
if [ "$hm_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would expire HM generations older than $hm_expiry_hm_format"
  else
    expire_hm_generations_if_available
  fi
fi

# Step 2: Nix store GC.
if [ "$nix_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would run nix-collect-garbage --delete-older-than $nix_expiry"
  else
    run_nix_gc_if_available
  fi
fi

# Step 3: stale wallpaper gc (independent of Nix).
if [ "$wallpaper_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would remove stale wallpapers"
  else
    gc_stale_wallpapers
  fi
fi

# Step 4: tool cache gc (independent of Nix, runs last).
if [ "$tool_cache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would clear tool caches"
  else
    gc_tool_caches_if_available
  fi
fi

# Step 5: remove orphaned Ollama models not declared in the manifest.
if [ "$ollama_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would gc stale Ollama models"
  else
    gc_ollama_models_if_available
  fi
fi

# Step 6: remove stale VM artifacts (temporary builds, orphaned images).
if [ "$vm_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    printf '%s\n' "gc: --dry-run: would gc stale VM artifacts"
  else
    gc_vm_artifacts_if_present
  fi
fi

# Step 7: Scoop cache gc (accepted but ignored on POSIX; Windows-only).
# This flag exists for cross-platform CLI parity with the Windows gc.ps1 script.

printf '%s\n' "gc: gc workflow completed"
