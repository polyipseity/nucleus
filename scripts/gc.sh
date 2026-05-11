#!/usr/bin/env sh
# Performs bounded garbage collection on POSIX hosts.
#
# Operations:
#   1. expire Home Manager generations older than 30 days (if home-manager is available)
#   2. run nix store garbage collection (if nix is available)
#   3. remove stale decrypted wallpaper files under ~/Pictures/wallpapers
#   4. prune cargo source/registry/advisory-db cache (if cargo-cache is available)
#   5. remove locally installed Ollama models absent from the manifest (if ollama is available)
#
# Arguments:
#   --skip-cargo-cache     skip cargo-cache -r all
#   --skip-hm-gc           skip home-manager expire-generations
#   --skip-nix-gc          skip nix-collect-garbage
#   --skip-ollama-prune    skip stale Ollama model removal
#   --skip-wallpaper-prune skip stale wallpaper cleanup
#
# Environment variables:
#   (none)
#
# Exit conditions:
#   0 on success; non-zero on failure.

set -eu

# Locate the nucleus repository root.  Resolution order:
#   1. ~/.config/nucleus/repo-root — written by apply.sh; reliable from
#      anywhere once apply has been run at least once.
#   2. git rev-parse --show-toplevel — works when CWD is inside the repo.
#      Stderr is suppressed because a non-repo CWD is expected and benign;
#      the exit code is checked via the conditional.
#   3. ~/dev/nucleus — canonical clone location declared in devRepos config.
resolve_nucleus_root() {
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  # Stderr suppressed: git failure when CWD is not inside a repository is
  # expected and benign; the exit code is checked via the conditional.
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$_rnr_git_root"
    return 0
  fi
  # Final fallback: canonical clone location declared in devRepos config.
  printf '%s\n' "$HOME/dev/nucleus"
}
REPO_ROOT="$(resolve_nucleus_root)"

skip_cargo_cache=false
skip_hm_gc=false
skip_nix_gc=false
skip_ollama_prune=false
skip_wallpaper_prune=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-cargo-cache)
      skip_cargo_cache=true
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
    --skip-wallpaper-prune)
      skip_wallpaper_prune=true
      ;;
    *)
      printf '%s\n' "gc: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

expire_hm_generations_if_available() {
  # Home Manager generations are GC roots: nix-collect-garbage cannot reclaim
  # store paths still referenced by live generations.  Expiring generations
  # older than 30 days before running Nix store GC releases those roots so
  # the subsequent collection can reclaim more.  30 days matches the
  # --delete-older-than window used for Nix store GC below.
  # Best-effort: hosts without a managed Home Manager profile will not have
  # home-manager in PATH.
  if ! command -v home-manager >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: home-manager unavailable; skipping generation expiry"
    return 0
  fi

  home-manager expire-generations "-30 days"
}

run_nix_gc_if_available() {
  # Store cleanup is best-effort because this helper also runs on hosts where
  # Nix may not be installed (for example minimal CI images).
  if ! command -v nix-collect-garbage >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: nix-collect-garbage unavailable; skipping Nix GC"
    return 0
  fi

  nix-collect-garbage --delete-older-than 30d
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

  managed_names_tmp=$(mktemp)
  trap 'rm -f "$managed_names_tmp"' EXIT INT TERM

  for asset in "$assets_dir"/*.sops; do
    if [ -f "$asset" ]; then
      basename "$asset" .sops >>"$managed_names_tmp"
    fi
  done

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

    if ! grep -Fxq "$candidate_name" "$managed_names_tmp"; then
      if ! rm -f "$candidate" 2>/dev/null; then
        # Non-fatal: some files under ~/Pictures may be protected by Finder
        # metadata/ACL flags (for example iCloud-managed placeholders). GC
        # should continue pruning other files even if one deletion is denied.
        printf '%s\n' "gc: warning: failed to remove stale wallpaper '$candidate'" >&2
      fi
    fi
  done
}

prune_cargo_cache_if_available() {
  # cargo-cache (github.com/matthiaskrgr/cargo-cache) reclaims space from
  # ~/.cargo/registry, ~/.cargo/git, and advisory-db clones that accumulate
  # across Rust development sessions.  Installed declaratively via
  # pkgs.cargo-cache on POSIX hosts.  This step is a no-op if the binary is
  # absent (for example on minimal CI images that do not have the full
  # package set).
  if ! command -v cargo-cache >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign on some hosts.
    printf '%s\n' "gc: cargo-cache unavailable; skipping cargo cache prune"
    return 0
  fi

  cargo_home_dir="${CARGO_HOME:-$HOME/.cargo}"
  if [ ! -d "$cargo_home_dir" ]; then
    printf '%s\n' "gc: cargo cache directory '$cargo_home_dir' is missing; skipping cargo cache prune"
    return 0
  fi

  if ! cargo-cache -r all; then
    printf '%s\n' "gc: warning: cargo-cache prune failed; continuing GC workflow" >&2
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

  "$REPO_ROOT/scripts/ai-sync.sh" --prune-only
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

# Step 4: cargo cache prune (independent of Nix, runs last).
if [ "$skip_cargo_cache" = false ]; then
  prune_cargo_cache_if_available
fi

# Step 5: remove orphaned Ollama models not declared in the manifest.
if [ "$skip_ollama_prune" = false ]; then
  prune_ollama_models_if_available
fi

printf '%s\n' "gc: gc workflow completed"
