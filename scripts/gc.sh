#!/usr/bin/env sh
# Performs bounded garbage collection on POSIX hosts.
#
# Operations:
#   1. expire Home Manager generations older than 30 days (if home-manager is available)
#   2. run nix store garbage collection (if nix is available)
#   3. remove stale decrypted wallpaper files under ~/Pictures/wallpapers
#   4. prune bun/cargo/rustc/uv caches and the repo-local .direnv environment
#   5. remove locally installed Ollama models absent from the manifest (if ollama is available)
#
# Arguments:
#   --skip-tool-cache-prune skip bun/cargo/rustc/uv and repo-local .direnv cache cleanup
#   --skip-hm-gc           skip home-manager expire-generations
#   --skip-nix-gc          skip nix-collect-garbage
#   --skip-ollama-prune    skip stale Ollama model removal
#   --skip-scoop-cleanup   accepted but ignored on POSIX (Windows-only)
#   --skip-wallpaper-prune skip stale wallpaper cleanup
#   --skip-vm-prune        skip stale VM artifact removal
#
# Environment variables:
#   (none)
#
# Exit conditions:
#   0 on success; non-zero on failure.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  cat <<'EOF'
usage: gc.sh [options]

  --skip-tool-cache-prune  Skip bun/cargo/rustc/uv cache cleanup.
  --skip-hm-gc             Skip home-manager generation expiration.
  --skip-nix-gc            Skip nix-collect-garbage.
  --skip-ollama-prune      Skip stale Ollama model removal.
  --skip-scoop-cleanup     Accepted but ignored on POSIX (Windows-only).
  --skip-wallpaper-prune   Skip stale wallpaper cleanup.
  --skip-vm-prune          Skip stale VM artifact removal.
EOF
}

REPO_ROOT="$(resolve_nucleus_root)"

skip_tool_cache_prune=false
skip_hm_gc=false
skip_nix_gc=false
skip_ollama_prune=false
skip_scoop_cleanup=false
skip_wallpaper_prune=false
skip_vm_prune=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-tool-cache-prune)
      skip_tool_cache_prune=true
      ;;
    --skip-hm-gc)
      skip_hm_gc=true
      ;;
    --skip-nix-gc)
      skip_nix_gc=true
      ;;
    --skip-ollama-prune)
      skip_ollama_prune=true
      ;;
    --skip-scoop-cleanup)
      skip_scoop_cleanup=true
      printf '%s\n' "gc: --skip-scoop-cleanup accepted but ignored on POSIX (Windows-only)"
      ;;
    --skip-wallpaper-prune)
      skip_wallpaper_prune=true
      ;;
    --skip-vm-prune)
      skip_vm_prune=true
      ;;
    *)
      printf '%s\n' "gc: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

expire_hm_generations_if_available() {
  # Home Manager generations are GC roots: nix-collect-garbage cannot reclaim
  # store paths still referenced by live generations.  Expiring generations
  # older than 7 days before running Nix store GC releases those roots so
  # the subsequent collection can reclaim more.  7 days matches the
  # --delete-older-than window used for Nix store GC below.
  # Best-effort: hosts without a managed Home Manager profile will not have
  # home-manager in PATH.
  if ! command -v home-manager >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: home-manager unavailable; skipping generation expiry"
    return 0
  fi

  home-manager expire-generations "-7 days"
}

run_nix_gc_if_available() {
  # Store cleanup is best-effort because this helper also runs on hosts where
  # Nix may not be installed (for example minimal CI images).
  if ! command -v nix-collect-garbage >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: nix-collect-garbage unavailable; skipping Nix GC"
    return 0
  fi

  nix-collect-garbage --delete-older-than 7d
}

prune_stale_wallpapers() {
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

prune_dir_contents_if_present() {
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
    printf '%s\n' "gc: warning: failed to prune $cache_label at '$cache_dir'" >&2
  fi
}

prune_tool_caches_if_available() {
  # bun/cargo/rustc/uv all accumulate user-scoped caches under HOME, regardless
  # of whether the binary came from the system profile or a direnv-loaded
  # devShell.  Clearing those shared cache locations reclaims space for both
  # system and devShell use without touching project-managed dependencies.
  # rustc has no standalone cache tree; its heavy artifacts live in cargo and
  # rustup-managed directories, which are pruned below.

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

  prune_dir_contents_if_present "$bun_cache_dir" "bun install cache"
  prune_dir_contents_if_present "$cargo_binstall_cache_dir" "cargo-binstall cache"
  prune_dir_contents_if_present "$rustup_tmp_dir" "rustup temporary cache"

  # cargo-cache (github.com/matthiaskrgr/cargo-cache) reclaims space from
  # ~/.cargo/registry, ~/.cargo/git, and advisory-db clones.  This remains the
  # authoritative cleanup path when the binary is available.
  if ! command -v cargo-cache >/dev/null 2>&1; then
    printf '%s\n' "gc: cargo-cache unavailable; skipping cargo cache prune"
  elif [ ! -d "$cargo_home_dir" ]; then
    printf '%s\n' "gc: cargo cache directory '$cargo_home_dir' is missing; skipping cargo cache prune"
  elif ! cargo-cache -r all; then
    printf '%s\n' "gc: warning: cargo-cache prune failed; continuing GC workflow" >&2
  fi

  prune_dir_contents_if_present "$uv_cache_dir" "uv cache"

  # direnv materializes the current repository's nix devShell under .direnv.
  # Clearing only the nucleus checkout keeps scope bounded to managed content;
  # unrelated repositories are left untouched.
  if [ -d "$repo_direnv_dir" ]; then
    if ! rm -rf "$repo_direnv_dir"; then
      printf '%s\n' "gc: warning: failed to remove repo-local direnv cache '$repo_direnv_dir'" >&2
    fi
  fi
}

prune_ollama_models_if_available() {
  # Remove locally installed Ollama models that are absent from the declarative
  # manifest at src/modules/ai/models.json.  Delegates to ai-sync.sh with
  # --prune-only so no new pulls are attempted during GC — a GC run should only
  # reclaim space, not trigger multi-GB model downloads.
  #
  # The probe below checks for both ollama and jq before delegating; ai-sync.sh
  # performs the same checks internally but printing a single skip message here
  # avoids noise from two separate absence warnings.
  if ! command -v ollama >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign before Ollama
    # has been provisioned on this host.
    printf '%s\n' "gc: ollama unavailable; skipping ollama model prune"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # jq is required by ai-sync.sh to parse the JSON manifest.
    printf '%s\n' "gc: jq unavailable; skipping ollama model prune"
    return 0
  fi

  # GC must stay space-reclaim only; do not wait for a cold Ollama daemon to
  # start because that would stall GC on hosts where the AI service is idle.
  OLLAMA_READY_TIMEOUT_SECONDS=0 "$REPO_ROOT/scripts/ai-sync.sh" --prune-only
}

prune_vm_artifacts_if_present() {
  # Remove stale VM artifacts from ~/virtual machines that accumulate across
  # provisioning cycles. This includes temporary Packer build directories and
  # pre-built images for VMs no longer declared in the manifest at
  # src/modules/VMs.json.
  #
  # WHY: VM disk images are large (multi-gigabyte); clearing stale files keeps
  # disk usage bounded and VM provisioning fast.
  if ! command -v jq >/dev/null 2>&1; then
    # jq is required to parse the manifest.
    printf '%s\n' "gc: jq unavailable; skipping VM artifact prune"
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
    printf '%s\n' "gc: manifest '$manifest' not found; skipping VM artifact prune" >&2
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
    printf '%s\n' "gc: failed to parse enabled VM names from '$manifest'; skipping VM artifact prune" >&2
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

  # Prune stale VM scripts from scripts/ subfolder.
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
if [ "$skip_hm_gc" = false ]; then
  expire_hm_generations_if_available
fi

# Step 2: Nix store GC.
if [ "$skip_nix_gc" = false ]; then
  run_nix_gc_if_available
fi

# Step 3: stale wallpaper cleanup (independent of Nix).
if [ "$skip_wallpaper_prune" = false ]; then
  prune_stale_wallpapers
fi

# Step 4: tool cache prune (independent of Nix, runs last).
if [ "$skip_tool_cache_prune" = false ]; then
  prune_tool_caches_if_available
fi

# Step 5: remove orphaned Ollama models not declared in the manifest.
if [ "$skip_ollama_prune" = false ]; then
  prune_ollama_models_if_available
fi

# Step 6: remove stale VM artifacts (temporary builds, orphaned images).
if [ "$skip_vm_prune" = false ]; then
  prune_vm_artifacts_if_present
fi

# Step 7: Scoop cache cleanup (accepted but ignored on POSIX; Windows-only).
# This flag exists for cross-platform CLI parity with the Windows gc.ps1 script.
if [ "$skip_scoop_cleanup" = true ]; then
  :
fi

printf '%s\n' "gc: gc workflow completed"
