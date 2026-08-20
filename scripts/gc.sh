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
  --git-cache-gc|--no-git-cache-gc  Control stale .git cache/state cleanup and git gc --auto (default: --git-cache-gc).
  --hm-gc|--no-hm-gc                        Control home-manager generation expiration (default: --hm-gc).
  --system-gc|--no-system-gc                Control system profile generation expiration (default: --system-gc).
  --nix-artifacts-gc|--no-nix-artifacts-gc  Control stale result symlink cleanup (default: --nix-artifacts-gc).
  --nix-gc|--no-nix-gc                      Control nix-collect-garbage (default: --nix-gc).
  --duperemove-gc|--no-duperemove-gc        Control btrfs duperemove on /nix/store (default: --duperemove-gc; root weekly GC only).
  --ollama-gc|--no-ollama-gc          Control stale Ollama model removal (default: --ollama-gc).
  --sccache-gc|--no-sccache-gc        Control sccache cache clearing (default: --sccache-gc).
  --wallpaper-gc|--no-wallpaper-gc    Control stale wallpaper gc (default: --wallpaper-gc).
  --vm-gc|--no-vm-gc                  Control stale VM artifact removal (default: --vm-gc).
  --vm-data-gc|--no-vm-data-gc        Also GC data/ writable disks during VM gc (default: --no-vm-data-gc).
  --log-gc|--no-log-gc                Control log rotation (default: --log-gc).
  --journald-gc|--no-journald-gc        Control journald log vacuum (default: --journald-gc).
  --log-max-size <bytes>              Log rotation max file size before rotation (default: 10000000).
  --log-max-files <count>             Number of rotated archives to keep (default: 4).
  --log-compress <true|false>         Compress rotated logs (default: true).
  --expiry <duration>                       Master expiry override (e.g. "14d"). Per-tool flags win (default: "7d").
  --generations-keep <count>                Master generation-count override (default: 7). Per-scope flags win.
  --hm-expiry <duration>                    Home Manager generation expiry duration in nix format (e.g. "7d").
  --hm-generations-keep <count>             Home Manager generations to keep (intersection with --hm-expiry).
  --nix-expiry <duration>                   Nix store GC --delete-older-than duration (e.g. "7d", "30d").
  --system-generations-keep <count>         System profile generations to keep (intersection with expiry).
  --dry-run|--no-dry-run                    Print actions without executing (default: --no-dry-run).
EOF
}

REPO_ROOT="$(derive_repo_root)"

tool_cache_gc=true
git_cache_gc="${NUCLEUS_GC_GIT_CACHE_GC:-true}"
hm_gc=true
system_gc=true
nix_artifacts_gc=true
nix_gc=true
duperemove_gc=true
ollama_gc=true
sccache_gc=true
wallpaper_gc=true
vm_gc=true
vm_data_gc=false
log_gc=true
journald_gc=true
dry_run=false
hm_expiry_arg=""
nix_expiry_arg=""
expiry_arg=""
generations_keep_arg=""
system_generations_keep_arg=""
hm_generations_keep_arg=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --tool-cache-gc)
    tool_cache_gc=true
    ;;
  --no-tool-cache-gc)
    tool_cache_gc=false
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
  --system-gc)
    system_gc=true
    ;;
  --no-system-gc)
    system_gc=false
    ;;
  --nix-artifacts-gc)
    nix_artifacts_gc=true
    ;;
  --no-nix-artifacts-gc)
    nix_artifacts_gc=false
    ;;
  --nix-gc)
    nix_gc=true
    ;;
  --no-nix-gc)
    nix_gc=false
    ;;
  --duperemove-gc)
    duperemove_gc=true
    ;;
  --no-duperemove-gc)
    duperemove_gc=false
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
  --vm-data-gc)
    vm_data_gc=true
    ;;
  --no-vm-data-gc)
    vm_data_gc=false
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
  --generations-keep)
    generations_keep_arg="$2"
    shift
    ;;
  --hm-expiry)
    hm_expiry_arg="$2"
    shift
    ;;
  --hm-generations-keep)
    hm_generations_keep_arg="$2"
    shift
    ;;
  --nix-expiry)
    nix_expiry_arg="$2"
    shift
    ;;
  --system-generations-keep)
    system_generations_keep_arg="$2"
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

# shellcheck source=../src/scripts/lib/expire-profile-generations.sh
. "$SCRIPT_DIR/../src/scripts/lib/expire-profile-generations.sh"

hm_expiry="${hm_expiry_arg:-${NUCLEUS_GC_HM_EXPIRY:-${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}}}"
nix_expiry="${nix_expiry_arg:-${NUCLEUS_GC_NIX_EXPIRY:-${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}}}"
system_expiry="${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"

_gc_user_only_pass=false
_gc_root_scheduler=false
if [ "${NUCLEUS_GC_USER_ONLY:-}" = true ]; then
  _gc_user_only_pass=true
  system_gc=false
  hm_gc=false
  nix_artifacts_gc=false
  nix_gc=false
  duperemove_gc=false
  journald_gc=false
elif [ "$(id -u)" -eq 0 ] && [ -n "${NUCLEUS_USERNAME:-}" ]; then
  _gc_root_scheduler=true
fi

_gc_dispatch_user_gc() {
  sudo -u "$NUCLEUS_USERNAME" -H env \
    NUCLEUS_GC_USER_ONLY=true \
    NUCLEUS_REPO_ROOT="$REPO_ROOT" \
    REPO_ROOT="$REPO_ROOT" \
    "$0" "$@"
}

_gc_skip_user_steps=false

generations_keep="${generations_keep_arg:-${NUCLEUS_GC_GENERATIONS_KEEP:-7}}"
system_generations_keep="${system_generations_keep_arg:-${NUCLEUS_GC_SYSTEM_GENERATIONS_KEEP:-${generations_keep}}}"
hm_generations_keep="${hm_generations_keep_arg:-${NUCLEUS_GC_HM_GENERATIONS_KEEP:-${generations_keep}}}"

_gc_run_as_target_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${NUCLEUS_USERNAME:-}" ]; then
    sudo -u "$NUCLEUS_USERNAME" -H "$@"
  else
    "$@"
  fi
}

expire_system_profile_generations() {
  _esp_profile=""
  if ! _esp_profile="$(resolve_system_profile)"; then
    say "no system profile found; skipping system generation expiry"
    return 0
  fi

  _esp_use_sudo=false
  if [ "$(uname -s)" = "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    _esp_use_sudo=true
  fi

  NUCLEUS_GC_PROFILE_SUDO="$_esp_use_sudo" \
    expire_profile_generations_intersection \
    "$_esp_profile" \
    "$system_generations_keep" \
    "$system_expiry" \
    "$dry_run"
}

expire_hm_profile_generations_body() {
  # shellcheck source=../src/scripts/lib/lib.sh
  . "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
  # shellcheck source=../src/scripts/lib/expire-profile-generations.sh
  . "$SCRIPT_DIR/../src/scripts/lib/expire-profile-generations.sh"
  _ehm_profile=""
  if ! _ehm_profile="$(resolve_hm_profile)"; then
    say "no Home Manager profile found; skipping HM generation expiry"
    return 0
  fi
  NUCLEUS_GC_PROFILE_SUDO=false \
    expire_profile_generations_intersection \
    "$_ehm_profile" \
    "$hm_generations_keep" \
    "$hm_expiry" \
    "$dry_run"
}

expire_hm_profile_generations() {
  export hm_generations_keep hm_expiry dry_run SCRIPT_DIR
  export -f expire_hm_profile_generations_body
  _gc_run_as_target_user bash -c "expire_hm_profile_generations_body"
}

run_nix_gc_if_available() {
  nix-collect-garbage --delete-older-than "$nix_expiry"
}

gc_duperemove_store_if_available() {
  _dds_script="$REPO_ROOT/src/scripts/services/duperemove-store.sh"
  if [ ! -f "$_dds_script" ]; then
    error "duperemove-store.sh not found at $_dds_script"
    return 1
  fi
  NUCLEUS_GC_DRY_RUN="$dry_run" "$_dds_script"
}

gc_nix_build_artifacts_if_present() {
  _cnba_options=""
  if [ "$dry_run" = true ]; then
    _cnba_options="--dry-run"
  fi
  # shellcheck source=../src/scripts/cleanup-nix-build-artifacts.sh
  . "$SCRIPT_DIR/../src/scripts/cleanup-nix-build-artifacts.sh"
}

gc_stale_wallpapers() {
  current_user="${USER:-$(id -un)}"
  output_dir="$HOME/Pictures/wallpapers"
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=../src/scripts/lib/resolve-user-config.sh
  . "$script_dir/../src/scripts/lib/resolve-user-config.sh"
  export NUCLEUS_REPO_ROOT="$REPO_ROOT"

  if [ ! -d "$output_dir" ]; then
    return 0
  fi

  for candidate in "$output_dir"/*; do
    [ -e "$candidate" ] || continue

    candidate_name=$(basename "$candidate")
    case "$candidate_name" in
    *.xml)
      continue
      ;;
    esac

    if [ -L "$candidate" ]; then
      if ! resolve_wallpaper_unencrypted_file "$current_user" "$candidate_name" >/dev/null 2>&1; then
        if ! rm -f "$candidate" 2>/dev/null; then
          warn "failed to remove stale wallpaper symlink '$candidate'"
        fi
      fi
      continue
    fi

    [ -f "$candidate" ] || continue

    if resolve_wallpaper_encrypted_blob "$current_user" "${candidate_name}.sops" >/dev/null 2>&1; then
      continue
    fi

    if ! rm -f "$candidate" 2>/dev/null; then
      warn "failed to remove stale wallpaper '$candidate'"
    fi
  done
}

gc_dir_contents_if_present() {
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

  if ! command -v cargo-cache >/dev/null 2>&1; then
    say "cargo-cache unavailable; skipping cargo cache gc"
  elif [ ! -d "$cargo_home_dir" ]; then
    say "cargo cache directory '$cargo_home_dir' is missing; skipping cargo cache gc"
  elif ! cargo-cache -r all; then
    warn "cargo-cache gc failed; continuing GC workflow"
  fi

  gc_dir_contents_if_present "$uv_cache_dir" "uv cache"

  if [ -d "$repo_direnv_dir" ]; then
    if ! rm -rf -- "$repo_direnv_dir"; then
      warn "failed to remove repo-local direnv cache '$repo_direnv_dir'"
    fi
  fi
}

gc_git_cache_if_present() {
  #
  dev_root="$HOME/dev"
  if [ ! -d "$dev_root" ]; then
    return 0
  fi

  while IFS= read -r -d '' gitdir; do
    repo_dir="$(dirname "$gitdir")"
    (
      cd "$repo_dir" 2>/dev/null || exit 0

      active_op=false
      for marker in ".git/MERGE_HEAD" ".git/rebase-merge" ".git/rebase-apply" ".git/BISECT_LOG" ".git/CHERRY_PICK_HEAD" ".git/REVERT_HEAD"; do
        if [ -e "$marker" ]; then
          active_op=true
          break
        fi
      done

      if [ -f ".git/gitk.cache" ]; then
        if [ "$dry_run" = true ]; then
          dry_run "would remove '.git/gitk.cache' in '$repo_dir'"
        else
          rm -f ".git/gitk.cache"
        fi
      fi

      if [ -f ".git/gc.log" ]; then
        if [ "$dry_run" = true ]; then
          dry_run "would remove '.git/gc.log' in '$repo_dir'"
        else
          rm -f ".git/gc.log"
        fi
      fi

      while IFS= read -r -d '' _lockfile; do
        if [ "$dry_run" = true ]; then
          dry_run "would remove lock file '$(printf '%s' "$_lockfile" | sed "s|^\./\.git/|.git/|")' in '$repo_dir'"
        else
          rm -f "$_lockfile"
        fi
      done < <(find ".git" -name '*.lock' ! -name 'index.lock' -type f -print0 2>/dev/null) # ref: allow-and-deny-lists.instructions.md#A5 -- Git invariant; index.lock must never be cleaned

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
  #
  if ! command -v ollama >/dev/null 2>&1; then
    say "ollama unavailable; skipping ollama model gc"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    say "jq unavailable; skipping ollama model gc"
    return 0
  fi

  nucleus-ai sync --gc-only
}

gc_sccache_cache_if_available() {
  clear_sccache_cache
}

gc_vm_artifacts_if_present() {
  #
  # WHY: keep-set has one source of truth in src/scripts/lib/vm.sh — vm_gc_vms
  vm_dir="${HOME}/virtual machines"
  src_dir="$vm_dir/src"
  manifest="$REPO_ROOT/src/modules/VMs.json"

  if [ ! -d "$vm_dir" ]; then
    return 0
  fi

  if [ ! -d "$src_dir" ]; then
    return 0
  fi

  if [ ! -f "$manifest" ]; then
    error "manifest '$manifest' not found; skipping VM artifact gc"
  fi

  require_command jq

  # WHY: an empty manifest would give vm_gc_vms an empty keep-set and delete
  vm_count="$(jq '.VMs | length' "$manifest")"
  if [ "$vm_count" -eq 0 ]; then
    return 0
  fi

  for _gc_type_dir in "$src_dir"/*/; do
    [ -d "$_gc_type_dir" ] || continue
    _gc_packer_dir="${_gc_type_dir}Packer"
    if [ -d "$_gc_packer_dir" ]; then
      if [ "$dry_run" = true ]; then
        dry_run "would remove temporary VM Packer directory '$(basename "$_gc_type_dir")/Packer'"
      elif rm -rf -- "$_gc_packer_dir" 2>/dev/null; then
        say "removed temporary VM Packer directory '$(basename "$_gc_type_dir")/Packer'"
      else
        warn "failed to remove temporary VM Packer directory '$_gc_packer_dir'"
      fi
    fi
  done

  for _gc_type_dir in "$src_dir"/*/; do
    [ -d "$_gc_type_dir" ] || continue
    for _gc_packer_tmp in "$_gc_type_dir"/.??*; do
      [ -d "$_gc_packer_tmp" ] || continue
      if [ "$dry_run" = true ]; then
        dry_run "would remove stale Packer temporary build directory: $(basename "$_gc_type_dir")/${_gc_packer_tmp##*/}"
      else
        warn "removing stale Packer temporary build directory: $(basename "$_gc_type_dir")/${_gc_packer_tmp##*/}"
        rm -rf -- "$_gc_packer_tmp"
      fi
    done
  done
  unset _gc_type_dir _gc_packer_dir _gc_packer_tmp

  if [ ! -f "$REPO_ROOT/scripts/vm.sh" ]; then
    error "vm.sh not found at '$REPO_ROOT/scripts/vm.sh'; cannot gc VM artifacts"
  fi
  _gc_vm_extra_args=()
  if [ "$dry_run" = true ]; then
    _gc_vm_extra_args+=(--dry-run)
  fi
  if [ "$vm_data_gc" = true ]; then
    _gc_vm_extra_args+=(--gc-data)
  fi
  "$REPO_ROOT/scripts/vm.sh" gc "${_gc_vm_extra_args[@]}"
}

if [ "$system_gc" = true ]; then
  expire_system_profile_generations
fi

if [ "$hm_gc" = true ]; then
  expire_hm_profile_generations
fi

if [ "$nix_artifacts_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale Nix build result symlinks"
  else
    gc_nix_build_artifacts_if_present
  fi
fi

if [ "$nix_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would run nix-collect-garbage --delete-older-than $nix_expiry"
  else
    run_nix_gc_if_available
  fi
fi

if [ "$_gc_root_scheduler" = true ] && [ "$duperemove_gc" = true ]; then
  gc_duperemove_store_if_available
fi

if [ "$_gc_root_scheduler" = true ]; then
  _gc_dispatch_user_gc "$@"
  _gc_skip_user_steps=true
fi

if [ "$_gc_skip_user_steps" != true ] && [ "$wallpaper_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale wallpapers"
  else
    gc_stale_wallpapers
  fi
fi

if [ "$_gc_skip_user_steps" != true ] && [ "$tool_cache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would clear tool caches"
  else
    gc_tool_caches_if_available
  fi
fi
if [ "$_gc_skip_user_steps" != true ] && [ "$git_cache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would remove stale .git cache/state files in ~/dev"
  else
    gc_git_cache_if_present
  fi
fi
if [ "$_gc_skip_user_steps" != true ] && [ "$ollama_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would gc stale Ollama models"
  else
    gc_ollama_models_if_available
  fi
fi

if [ "$_gc_skip_user_steps" != true ] && [ "$sccache_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would clear sccache cache"
  else
    gc_sccache_cache_if_available
  fi
fi

if [ "$_gc_skip_user_steps" != true ] && [ "$vm_gc" = true ]; then
  gc_vm_artifacts_if_present
fi

gc_logs() {
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
  _gl_expiry="${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"

  rotate_logs_in_directory "$_gl_log_dir" "$_gl_maxsize" "$_gl_maxfiles" "$_gl_compress"
  expire_logs_in_directory "$_gl_log_dir" "$_gl_expiry"

  if [ -n "$_gl_system_log_dir" ] && [ "$_gl_system_log_dir" != "$_gl_log_dir" ]; then
    if [ -w "$_gl_system_log_dir" ]; then
      rotate_logs_in_directory "$_gl_system_log_dir" "$_gl_maxsize" "$_gl_maxfiles" "$_gl_compress"
      expire_logs_in_directory "$_gl_system_log_dir" "$_gl_expiry"
    elif command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
      say "system log dir '$_gl_system_log_dir' not writable by current user; escalating to root"
      sudo env NUCLEUS_REPO_ROOT="$REPO_ROOT" NUCLEUS_GC_EXPIRY="$_gl_expiry" \
        "$REPO_ROOT/src/scripts/services/log-gc-system.sh"
    else
      warn "system log dir '$_gl_system_log_dir' not writable and cannot escalate; skipping"
    fi
  fi
}

if [ "$_gc_skip_user_steps" != true ] && [ "$log_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would rotate managed logs"
  else
    gc_logs
  fi
fi

gc_journald_if_available() {
  #
  if ! command -v journalctl >/dev/null 2>&1; then
    say "journalctl unavailable; skipping journald vacuum"
    return 0
  fi

  _jv_expiry="${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"
  # check-suppress:suppression_doc: journal may not exist on non-systemd systems; best-effort vacuum.
  journalctl --vacuum-time="$_jv_expiry" 2>/dev/null || true
}

if [ "$journald_gc" = true ]; then
  if [ "$dry_run" = true ]; then
    dry_run "would vacuum journald logs older than ${expiry_arg:-${NUCLEUS_GC_EXPIRY:-7d}}"
  else
    gc_journald_if_available
  fi
fi

nuc_done "$@"
