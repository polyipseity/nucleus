#!/usr/bin/env bash
# Expires old Home Manager generations, runs nix store GC, removes stale
# decrypted wallpapers, gc's tool caches, and removes locally installed
# Ollama models absent from the manifest.

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

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  --tool-cache-gc|--no-tool-cache-gc  Control bun/cargo/rustc/uv cache gc (default: --tool-cache-gc).
  --git-template-gc|--no-git-template-gc  Control stale .git hooks/description cleanup (default: --git-template-gc).
  --git-cache-gc|--no-git-cache-gc  Control stale .git cache/state cleanup and git gc --auto (default: --git-cache-gc).
  --hm-gc|--no-hm-gc                        Control home-manager generation expiration (default: --hm-gc).
  --nix-gc|--no-nix-gc                      Control nix-collect-garbage (default: --nix-gc).
  --ollama-gc|--no-ollama-gc          Control stale Ollama model removal (default: --ollama-gc).
  --sccache-gc|--no-sccache-gc        Control sccache cache clearing (default: --sccache-gc).
  --wallpaper-gc|--no-wallpaper-gc    Control stale wallpaper gc (default: --wallpaper-gc).
  --vm-gc|--no-vm-gc                  Control stale VM artifact removal (default: --vm-gc).
  --log-gc|--no-log-gc                Control log rotation (default: --log-gc).
  --journald-gc|--no-journald-gc        Control journald log vacuum (default: --journald-gc).
  --log-max-size <bytes>              Log rotation max file size before rotation (default: 10000000).
  --log-max-files <count>             Number of rotated archives to keep (default: 4).
  --log-compress <true|false>         Compress rotated logs (default: true).
  --expiry <duration>                       Master expiry override (e.g. "14d"). Per-tool flags win (default: "7d").
  --hm-expiry <duration>                    Home Manager generation expiry duration in nix format (e.g. "7d").
  --nix-expiry <duration>                   Nix store GC --delete-older-than duration (e.g. "7d", "30d").
  --dry-run|--no-dry-run                    Print actions without executing (default: --no-dry-run).
EOF
}

REPO_ROOT="$(derive_repo_root)"

tool_cache_gc=true
git_template_gc=true
git_cache_gc="${NUCLEUS_GC_GIT_CACHE_GC:-true}"
hm_gc=true
nix_gc=true
ollama_gc=true
sccache_gc=true
wallpaper_gc=true
vm_gc=true
log_gc=true
journald_gc=true
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
    --git-template-gc)
      git_template_gc=true
      ;;
    --no-git-template-gc)
      git_template_gc=false
      ;;
    --git-cache-gc)
      git_cache_gc=true
      ;;
    --no-git-cache-gc)
      git_cache_gc=false
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
    --sccache-gc)
      sccache_gc=true
      ;;
    --no-sccache-gc)
      sccache_gc=false
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
    --log-gc)
      log_gc=true
      ;;
    --no-log-gc)
      log_gc=false
      ;;
    --journald-gc)
      journald_gc=true
      ;;
    --no-journald-gc)
      journald_gc=false
      ;;
    --log-max-size)
      log_max_size="$2"
      shift
      ;;
    --log-max-files)
      log_max_files="$2"
      shift
      ;;
    --log-compress)
      log_compress="$2"
      shift
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
      error "unsupported argument '$1'"
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
    say "home-manager unavailable; skipping generation expiry"
    return 0
  fi

  home-manager expire-generations "$hm_expiry_hm_format"
}

run_nix_gc_if_available() {
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
        warn "failed to remove stale wallpaper '$candidate'"
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

  if ! find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
    warn "failed to gc $cache_label at '$cache_dir'"
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
    say "cargo-cache unavailable; skipping cargo cache gc"
  elif [ ! -d "$cargo_home_dir" ]; then
    say "cargo cache directory '$cargo_home_dir' is missing; skipping cargo cache gc"
  elif ! cargo-cache -r all; then
    warn "cargo-cache gc failed; continuing GC workflow"
  fi

  gc_dir_contents_if_present "$uv_cache_dir" "uv cache"

  # direnv materializes the current repository's nix devShell under .direnv.
  # Clearing only the nucleus checkout keeps scope bounded to managed content;
  # unrelated repositories are left untouched.
  if [ -d "$repo_direnv_dir" ]; then
    if ! rm -rf -- "$repo_direnv_dir"; then
      warn "failed to remove repo-local direnv cache '$repo_direnv_dir'"
    fi
  fi
}

gc_git_templates_if_present() {
  # Remove boilerplate files from existing .git directories under ~/dev that
  # were created before init.templateDir was configured.  Cleans sample hook
  # scripts and the legacy description file from every .git found.
  #
  # The preventative init.templateDir setting (in git.nix /
  # Sync-GitAndSshConfig.ps1) stops new repos from getting these files, but
  # existing repos need a one-time sweep.  After this, git-init and git-clone
  # on all three platforms will create clean minimal .git dirs.
  dev_root="$HOME/dev"
  if [ ! -d "$dev_root" ]; then
    return 0
  fi

  while IFS= read -r -d '' gitdir; do
    # check-suppress:suppression_doc: glob may match nothing; rm -f errors are non-fatal
    rm -f "$gitdir/hooks/"*.sample 2>/dev/null || true
    # check-suppress:suppression_doc: description may already be absent; rm -f errors are non-fatal
    rm -f "$gitdir/description" 2>/dev/null || true
  done < <(find "$dev_root" -name ".git" -type d -print0 2>/dev/null)
}

gc_git_cache_if_present() {
  # Remove stale .git cache and state files from repos under ~/dev.
  # Complements gc_git_templates_if_present() with deeper cleanup: gitk
  # cache, gc.log, stale lock files, abandoned merge/rebase/bisect state,
  # deprecated directories (branches/, remotes/), refs/original/, and
  # delegated cleanup via `git gc --auto`.
  #
  # Active operation detection (MERGE_HEAD, rebase-merge/, BISECT_LOG, etc.)
  # is done per-repo; state file removal is skipped for repos with
  # in-progress operations.
  dev_root="$HOME/dev"
  if [ ! -d "$dev_root" ]; then
    return 0
  fi

  while IFS= read -r -d '' gitdir; do
    repo_dir="$(dirname "$gitdir")"
    (
      cd "$repo_dir" 2>/dev/null || exit 0

      # Detect active Git operation.
      active_op=false
      for marker in ".git/MERGE_HEAD" ".git/rebase-merge" ".git/rebase-apply" ".git/BISECT_LOG" ".git/CHERRY_PICK_HEAD" ".git/REVERT_HEAD"; do
        if [ -e "$marker" ]; then
          active_op=true
          break
        fi
      done

      # Remove gitk cache.
      if [ -f ".git/gitk.cache" ]; then
        if [ "$dry_run" = true ]; then
          dry_run "would remove '.git/gitk.cache' in '$repo_dir'"
        else
          rm -f ".git/gitk.cache"
        fi
      fi

      # Remove gc.log (allows git gc --auto to run again).
      if [ -f ".git/gc.log" ]; then
        if [ "$dry_run" = true ]; then
          dry_run "would remove '.git/gc.log' in '$repo_dir'"
        else
          rm -f ".git/gc.log"
        fi
      fi

      # Remove lock files except index.lock.
      while IFS= read -r -d '' _lockfile; do
        if [ "$dry_run" = true ]; then
          dry_run "would remove lock file '$(printf '%s' "$_lockfile" | sed "s|^\./\.git/|.git/|")' in '$repo_dir'"
        else
          rm -f "$_lockfile"
        fi
      done < <(find ".git" -name '*.lock' ! -name 'index.lock' -type f -print0 2>/dev/null)  # ref: allow-and-deny-lists.instructions.md#A5 — reason: Git invariant; index.lock must never be cleaned

      # Remove stale state files when no active operation.
      # Uses dynamic glob patterns to discover stale files, so new Git state
      # files are automatically picked up without maintaining a hard-coded list.
      if [ "$active_op" = false ]; then
        while IFS= read -r -d '' _state_file; do
          _state_file="${_state_file#./}"
          if [ "$dry_run" = true ]; then
            dry_run "would remove stale state file '$_state_file' in '$repo_dir'"
          else
            rm -f "$_state_file"
          fi
        done < <(find ".git" -type f \( -name '*_HEAD' -o -name 'BISECT_*' -o -name 'AUTO_MERGE' -o -name 'SQUASH_MSG' \) -print0 2>/dev/null)
      fi

      # Remove deprecated directories if empty.
      for _dep_dir in ".git/branches" ".git/remotes"; do
        if [ -d "$_dep_dir" ]; then
          if ! find "$_dep_dir" -mindepth 1 -maxdepth 1 | head -n 1 | grep -q .; then
            if [ "$dry_run" = true ]; then
              dry_run "would remove empty deprecated directory '$_dep_dir' in '$repo_dir'"
            else
              # check-suppress:suppression_doc: race -- directory may no longer be empty between check and removal
              rmdir "$_dep_dir" 2>/dev/null || true
            fi
          fi
        fi
      done

      # Remove refs/original/ via git update-ref (handles packed-refs).
      if git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | grep -q .; then
        if [ "$dry_run" = true ]; then
          dry_run "would remove refs/original/ in '$repo_dir'"
        else
          git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while IFS= read -r _ref; do
            # check-suppress:suppression_doc: ref may have been deleted by concurrent gc
            git update-ref -d "$_ref" 2>/dev/null || true
          done
          # check-suppress:suppression_doc: directory may not exist or may not be empty
          rmdir ".git/refs/original" 2>/dev/null || true
        fi
      fi

      # Run git gc --auto (delegates object pruning, reflog expiry, etc.
      # to Git).  --auto is a no-op when nothing needs gc.
      if [ "$dry_run" = true ]; then
        dry_run "would run 'git gc --auto' in '$repo_dir'"
      else
        # check-suppress:suppression_doc: some repos may have errors during gc
        git gc --auto 2>/dev/null || true
      fi
    )
  done < <(find "$dev_root" -name ".git" -type d -print0 2>/dev/null)
}

gc_ollama_models_if_available() {
  # Remove locally installed Ollama models that are absent from the declarative
  # manifest at src/modules/ai/models.json.  Delegates to nucleus-ai sync with
  # --gc-only so no new pulls are attempted during GC — a GC run should only
  # reclaim space, not trigger multi-GB model downloads.
  #
  # The probe below checks for both ollama and jq before delegating; nucleus-ai
  # performs the same checks internally but printing a single skip message here
  # avoids noise from two separate absence warnings.
  if ! command -v ollama >/dev/null 2>&1; then
    # Existence probe — tool absent is expected and benign before Ollama
    # has been provisioned on this host.
    say "ollama unavailable; skipping ollama model gc"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # jq is required by nucleus-ai to parse the JSON manifest.
    say "jq unavailable; skipping ollama model gc"
    return 0
  fi

  # GC must stay space-reclaim only; do not wait for a cold Ollama daemon to
  # start because that would stall GC on hosts where the AI service is idle.
  nucleus-ai sync --gc-only
}

gc_sccache_cache_if_available() {
  if ! command -v sccache >/dev/null 2>&1; then
    say "sccache unavailable; skipping sccache cache gc"
    return 0
  fi
  say "sccache: clearing cache"
  if [ "$dry_run" = true ]; then
    dry_run "would run 'sccache --clear'"
  elif ! sccache --clear; then
    warn "sccache --clear failed; continuing GC workflow"
  fi
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
    say "jq unavailable; skipping VM artifact gc"
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
    error "manifest '$manifest' not found; skipping VM artifact gc"
  fi

  vm_count=$(jq '.VMs | length' "$manifest" 2>/dev/null || printf '%s\n' "0")
  if [ "$vm_count" -eq 0 ]; then
    return 0
  fi

  # Build a list of enabled VM names (disabled VMs are treated as stale).
  declared_names_tmp=$(mktemp)

  if ! jq -r '.VMs[] | select(.enabled == true) | .name' "$manifest" >"$declared_names_tmp" 2>/dev/null; then
    rm -f "$declared_names_tmp"
    error "failed to parse enabled VM names from '$manifest'; skipping VM artifact gc"
  fi

  # Remove temporary Packer build directories.
  for build_dir in "$images_dir"/*-build; do
    if [ -d "$build_dir" ]; then
      if rm -rf -- "$build_dir" 2>/dev/null; then
        say "removed temporary VM build directory '$(basename "$build_dir")'"
      else
        warn "failed to remove temporary VM build directory '$build_dir'"
      fi
    fi
  done

  # Remove leftover Packer temporary build directories (dot-prefixed, from interrupted runs).
  if [ -d "$images_dir" ]; then
    for _gc_packer_tmp in "$images_dir"/.??*; do
      [ -d "$_gc_packer_tmp" ] || continue
      warn "removing stale Packer temporary build directory: ${_gc_packer_tmp##*/}"
      rm -rf -- "$_gc_packer_tmp"
    done
    unset _gc_packer_tmp
  fi

  # Remove stale VM disk images (qcow2) for VMs not declared in the manifest.
  for qcow2_file in "$images_dir"/*.qcow2; do
    if [ -f "$qcow2_file" ]; then
      qcow2_name=$(basename "$qcow2_file" .qcow2)
      if ! grep -Fxq "$qcow2_name" "$declared_names_tmp"; then
        if rm -f "$qcow2_file" 2>/dev/null; then
          say "removed stale VM disk image '$(basename "$qcow2_file")'"
        else
          warn "failed to remove stale VM disk image '$qcow2_file'"
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
        say "removed stale VM script '$_gc_base'"
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
    dry_run "would expire HM generations older than $hm_expiry_hm_format"
  else
    expire_hm_generations_if_available
  fi
fi

# Step 2: Nix store GC.
if [ "$nix_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would run nix-collect-garbage --delete-older-than $nix_expiry"
  else
    run_nix_gc_if_available
  fi
fi

# Step 3: stale wallpaper gc (independent of Nix).
if [ "$wallpaper_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale wallpapers"
  else
    gc_stale_wallpapers
  fi
fi

# Step 4: tool cache gc (independent of Nix, runs last).
if [ "$tool_cache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would clear tool caches"
  else
    gc_tool_caches_if_available
  fi
fi
# Step 5: remove stale .git boilerplate (sample hooks, description) from ~/dev.
if [ "$git_template_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale .git template boilerplate from ~/dev"
  else
    gc_git_templates_if_present
  fi
fi
# Step 6: remove stale .git cache/state files and run git gc --auto in ~/dev.
if [ "$git_cache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale .git cache/state files in ~/dev"
  else
    gc_git_cache_if_present
  fi
fi
# Step 7: remove orphaned Ollama models not declared in the manifest.
if [ "$ollama_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would gc stale Ollama models"
  else
    gc_ollama_models_if_available
  fi
fi

# Step 7b: clear sccache compilation cache.
if [ "$sccache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would clear sccache cache"
  else
    gc_sccache_cache_if_available
  fi
fi

# Step 8: remove stale VM artifacts (temporary builds, orphaned images).
if [ "$vm_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would gc stale VM artifacts"
  else
    gc_vm_artifacts_if_present
  fi
fi

gc_logs() {
  # Rotate managed log files via copy-truncate (preserves inodes).
  services_json="$REPO_ROOT/src/modules/services.json"
  services_schema_json="$REPO_ROOT/src/modules/services.schema.json"
  if [ ! -f "$services_json" ]; then
    say "services.json not found; skipping log rotation"
    return 0
  fi

  _gl_maxsize="${log_max_size:-$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$services_schema_json")}" # bytes
  _gl_maxfiles="${log_max_files:-$(jq -r '.definitions.loggingEntry.properties.maxFiles.default // 4' "$services_schema_json")}"
  _gl_compress="${log_compress:-$(jq -r '.definitions.loggingEntry.properties.compress.default // "true"' "$services_schema_json")}"

  _gl_log_dir="$(nucleus_log_dir)"
  _gl_system_log_dir="$(nucleus_system_log_dir)"

  rotate_logs_in_directory "$_gl_log_dir" "$_gl_maxsize" "$_gl_maxfiles" "$_gl_compress"

  if [ -n "$_gl_system_log_dir" ] && [ "$_gl_system_log_dir" != "$_gl_log_dir" ]; then
    rotate_logs_in_directory "$_gl_system_log_dir" "$_gl_maxsize" "$_gl_maxfiles" "$_gl_compress"
  fi
}

# Step 9: rotate managed log files via copy-truncate (preserves inodes).
if [ "$log_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would rotate managed logs"
  else
    gc_logs
  fi
fi

gc_journald_if_available() {
  # Vacuum journald logs older than the configured expiry.
  # Uses the master expiry ($expiry_arg -> 7d default) so journald GC is
  # aligned with other retention windows in this script.
  #
  # journald vacuum preserves at minimum the specified time, so on NixOS
  # where all service logs go through journald, this ensures old logs are
  # reclaimed on the same schedule as file-based logs.
  if ! command -v journalctl >/dev/null 2>&1; then
    say "journalctl unavailable; skipping journald vacuum"
    return 0
  fi

  _jv_expiry="${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"
  # check-suppress:suppression_doc: journal may not exist on non-systemd systems; best-effort vacuum.
  journalctl --vacuum-time="$_jv_expiry" 2>/dev/null || true
}

# Step 10: vacuum journald logs (NixOS only; no-op on macOS/Windows).
if [ "$journald_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would vacuum journald logs older than ${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"
  else
    gc_journald_if_available
  fi
fi

# Step 11: Scoop cache gc (accepted but ignored on POSIX; Windows-only).
# This flag exists for cross-platform CLI parity with the Windows gc.ps1 script.

nuc_done
