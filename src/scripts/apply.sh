#!/usr/bin/env bash
# OS detection, lifecycle ordering (pre-apply checks → rebuild → post-apply
# provisioning), and error-boundary handling. Heavy logic in sibling scripts.
set -euo pipefail

# Refuse to run as root — privilege escalation (sudo) is managed internally
# by the script when needed rather than relying on an already-elevated caller.
if [ "$(id -u)" -eq 0 ]; then
  printf '%s\n' "error: this script must not be run as root. Run as a regular user (sudo is used internally when needed)." >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=lib/lib.sh
. "$SCRIPT_DIR/lib/lib.sh"

# Usage
usage() {
  usage_std 'apply.sh' '[--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--store-audit|--no-store-audit] [--target-user=<name>] [--username=<name>] [--vm-sync|--no-vm-sync] [--vm-setup|--no-vm-setup]' \
    'Dispatch the Nix apply command for the current host.'
  exit 0
}

# ── Subcommand dispatch ───────────────────────────────────────────────────────
# health-check / audit-store run standalone (inlining scripts/health-check.sh
# and scripts/audit-store.sh); the default apply path falls through to the
# existing flag parsing + OS-specific rebuild flow below, which stays unchanged.
#
# do_health_check — Inlines scripts/health-check.sh: disk/connectivity/secret
# (and opt-in log/store-audit) pre-flight checks.
do_health_check() {
  REPO_ROOT="$(derive_repo_root)"

  min_free_bytes=10000000000
  secret_health=true
  log_health=false
  store_audit=false

  if [ "${NUCLEUS_HEALTH_CHECK_STORE_AUDIT:-}" = "1" ]; then
    store_audit=true
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      ;;
    --min-free-bytes)
      if [ "$#" -lt 2 ]; then
        error "--min-free-bytes requires a value"
        exit 1
      fi
      min_free_bytes="$2"
      shift
      ;;
    --secret-health)
      secret_health=true
      ;;
    --no-secret-health)
      secret_health=false
      ;;
    --log-health)
      log_health=true
      require_command jq
      ;;
    --store-audit)
      store_audit=true
      ;;
    --no-store-audit)
      store_audit=false
      ;;
    *)
      error "unsupported argument '$1'"
      exit 1
      ;;
    esac
    shift
  done

  # check_disk_space — Fails when the repo filesystem has less free space than
  # the threshold.
  check_disk_space() {
    min_kb=$((min_free_bytes / 1024))
    available_kb=$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print $4 }')

    if [ -z "$available_kb" ] || [ "$available_kb" -lt "$min_kb" ]; then
      error "insufficient disk space at repo filesystem (${available_kb:-0} KiB available, requires ${min_kb} KiB)."
    fi

    return 0
  }

  # check_connectivity — Verifies reachability of GitHub and cache.nixos.org.
  check_connectivity() {
    if ! curl -fsSI --max-time 10 https://github.com >/dev/null; then
      error "connectivity check failed for https://github.com"
    fi

    if ! curl -fsSI --max-time 10 https://cache.nixos.org >/dev/null; then
      error "connectivity check failed for https://cache.nixos.org"
    fi

    return 0
  }

  # check_secret_health — Decrypt-checks every SOPS-managed secret file.
  check_secret_health() {
    _sch_machine_key="/etc/sops/age/machine.txt"
    if [ -f "$_sch_machine_key" ]; then
      SOPS_AGE_KEY_FILE="$_sch_machine_key"
      export SOPS_AGE_KEY_FILE
    fi

    for secret_file in "$REPO_ROOT"/src/secrets/users/*.yml; do
      if [ -f "$secret_file" ] && ! sops -d "$secret_file" >/dev/null; then
        error "unable to decrypt secret file with current identities: $secret_file"
      fi
    done

    return 0
  }

  # check_log_health — Validates log dirs and per-service log files against the
  # rotation and sanitize policy in services.json.
  check_log_health() {
    log_dir="$(nucleus_log_dir)"
    system_log_dir="$(nucleus_system_log_dir)"
    services_json="$REPO_ROOT/src/modules/services.json"
    services_schema_json="$REPO_ROOT/src/modules/services.schema.json"
    _max_size_default=$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$services_schema_json")
    failures=0

    for dir in "$log_dir" "$system_log_dir"; do
      if [ -d "$dir" ]; then
        if [ ! -w "$dir" ]; then
          warn "log dir '$dir' is not writable"
          failures=$((failures + 1))
        fi
      else
        warn "log dir '$dir' does not exist"
        failures=$((failures + 1))
      fi
    done

    while IFS= read -r svc; do
      capture=$(jq -r --arg svc "$svc" '.[$svc].logging.capture // "all"' "$services_json")
      max_size=$(jq -r --arg svc "$svc" --arg def "$_max_size_default" '(.[$svc].logging.maxSize // ($def | tonumber))' "$services_json") # bytes
      sanitize=$(jq -r --arg svc "$svc" '.[$svc].logging.sanitize // true' "$services_json")

      if [ "$capture" = "none" ]; then
        continue
      fi

      while IFS= read -r subdir; do
        [ -n "$subdir" ] || continue
        for log_file in "$log_dir/$subdir"/*.log; do
          [ -f "$log_file" ] || continue

          size=$(wc -c <"$log_file")
          threshold=$((max_size * 80 / 100))
          if [ "$size" -gt "$threshold" ]; then
            warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
          fi

          if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
            warn "'$log_file' contains control characters despite sanitize=true"
            failures=$((failures + 1))
          fi
        done
      done <<<"$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.user[]? // empty' "$services_json")"

      while IFS= read -r subdir; do
        [ -n "$subdir" ] || continue
        for log_file in "$system_log_dir/$subdir"/*.log; do
          [ -f "$log_file" ] || continue

          size=$(wc -c <"$log_file")
          threshold=$((max_size * 80 / 100))
          if [ "$size" -gt "$threshold" ]; then
            warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
          fi

          if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
            warn "'$log_file' contains control characters despite sanitize=true"
            failures=$((failures + 1))
          fi
        done
      done <<<"$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.system[]? // empty' "$services_json")"
    done <<<"$(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$services_json" | sort)"

    if [ "$failures" -gt 0 ]; then
      error "log health checks failed ($failures issue(s))"
    fi
    return 0
  }

  check_disk_space
  check_connectivity
  if [ "$secret_health" = true ]; then
    check_secret_health
  fi
  if [ "$log_health" = true ]; then
    check_log_health
  fi
  if [ "$store_audit" = true ] && command -v nix >/dev/null 2>&1; then
    require_command jq
    export REPO_ROOT
    # shellcheck source=lib/audit-store.sh
    . "$SCRIPT_DIR/lib/audit-store.sh"
    audit_store_report
  fi

  nuc_done "$@"
}

# do_audit_store — Inlines scripts/audit-store.sh: Nix store baseline report.
do_audit_store() {
  REPO_ROOT="$(derive_repo_root)"
  export REPO_ROOT
  # shellcheck source=lib/audit-store.sh
  . "$SCRIPT_DIR/lib/audit-store.sh"
  audit_store_report
  nuc_done "$@"
}

action="${1:-apply}"
case "$action" in
health-check)
  shift
  do_health_check "$@"
  exit $?
  ;;
audit-store)
  shift
  do_audit_store "$@"
  exit $?
  ;;
apply)
  :
  ;;
*)
  action="apply"
  ;;
esac

# Flag parsing
ai_sync=true
replica_sync=false
vm_sync=true
vm_setup=false
store_audit=false
target_user=""

if [ "${NUCLEUS_HEALTH_CHECK_STORE_AUDIT:-}" = "1" ]; then
  store_audit=true
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
  --ai-sync) ai_sync=true ;;
  --no-ai-sync) ai_sync=false ;;
  --replica-sync) replica_sync=true ;;
  --no-replica-sync) replica_sync=false ;;
  --vm-sync) vm_sync=true ;;
  --no-vm-sync) vm_sync=false ;;
  --vm-setup) vm_setup=true ;;
  --no-vm-setup) vm_setup=false ;;
  --store-audit) store_audit=true ;;
  --no-store-audit) store_audit=false ;;
  --target-user)
    target_user="$2"
    shift
    if [ -z "$target_user" ]; then
      error -l apply "--target-user requires a non-empty value"
      exit 1
    fi
    ;;
  --target-user=*)
    target_user="${1#--target-user=}"
    if [ -z "$target_user" ]; then
      error -l apply "--target-user requires a non-empty value"
      exit 1
    fi
    ;;
  --username)
    NUCLEUS_USERNAME="$2"
    shift
    if [ -z "$NUCLEUS_USERNAME" ]; then
      error -l apply "--username requires a non-empty value"
      exit 1
    fi
    ;;
  -h | --help)
    usage
    ;;
  *)
    error -l apply "unsupported argument '$1'"
    exit 1
    ;;
  esac
  shift
done

REPO_ROOT="$(derive_repo_root)"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

# Prefer the live checkout when nucleus-apply dispatches a store snapshot.
# WHY: store-bundled apply.sh can lag behind git pull until the next rebuild.
_aar_self="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
_aar_live="$REPO_ROOT/src/scripts/apply.sh"
if [ -f "$_aar_live" ]; then
  _aar_live_resolved="$(CDPATH='' cd -P -- "$(dirname -- "$_aar_live")" && pwd)/$(basename -- "$_aar_live")"
  if [ "$_aar_self" != "$_aar_live_resolved" ]; then
    exec "$_aar_live" "$@"
  fi
fi
unset _aar_self _aar_live _aar_live_resolved

# Augment PATH with the user Nix profile bin directory so Nix-managed binaries
# (e.g. ssh-to-age, sops) are available when the script is invoked directly
# rather than through `nix run .#apply` (which adds them via runtimeInputs).
# The guard avoids redundant PATH modifications when already present.
_nix_profile_bin="$HOME/.nix-profile/bin"
case ":$PATH:" in
*":$_nix_profile_bin:"*) ;;
*)
  if [ -d "$_nix_profile_bin" ]; then
    PATH="$PATH:$_nix_profile_bin"
    export PATH
  fi
  ;;
esac
unset _nix_profile_bin

# Resolve src/scripts/ for apply-internal script delegation.
_ash_script_dir="$(cd "$(dirname -- "$0")" && pwd -P)"

# Generate key-catalog.json from decrypted system.yml so Nix modules
# (sops.nix, ai.nix) can discover available AI API keys and their env var
# mappings at evaluation time.  Must run before any nix build/eval.
# Output goes to the nucleus USER root (not the repo tree) so generated content
# stays out of git.  NUCLEUS_CATALOG_PATH is exported for Nix consumers.
# shellcheck source=lib/key-catalog.sh
. "$SCRIPT_DIR/lib/key-catalog.sh"
ensure_key_catalog

# Symlink the LiteLLM config so edits take effect on service restart without
# re-running apply.  All host services (macOS launchd, NixOS systemd, Windows
# scheduled task) reference this well-known path.
ln -sf "$REPO_ROOT/src/modules/ai/litellm-config.yml" "$NUCLEUS_USER_ROOT/litellm-config.yml"

run_nix() {
  NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" nix --option warn-dirty false "$@"
}

run_nix_as_root() {
  # Forward NUCLEUS_REPO_ROOT so builtins.getEnv in Nix config can construct
  # writable out-of-store symlinks during evaluation.  Color env vars and TERM
  # keep nix build-progress rendering intact; empty values are treated as
  # unset by _nuc_color_init, keeping non-color runs byte-identical.  Note:
  # activation scripts never receive these vars — nix-darwin's generated
  # activate script runs under `#!/usr/bin/env -i`, wiping the env before any
  # activation script executes, so activation output is plain by design (see
  # logging spec "External exceptions").
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env \
    "NIX_CONFIG=$NIX_CONFIG_VALUE" \
    "NIX_PATH=nixpkgs=flake:nixpkgs" \
    "NUCLEUS_REPO_ROOT=${NUCLEUS_REPO_ROOT}" \
    "NUCLEUS_CATALOG_PATH=${NUCLEUS_CATALOG_PATH:-}" \
    "FORCE_COLOR=${FORCE_COLOR:-}" \
    "NO_COLOR=${NO_COLOR:-}" \
    "CLICOLOR_FORCE=${CLICOLOR_FORCE:-}" \
    "TERM=${TERM:-}" \
    nix --option warn-dirty false "$@"
}

start_sudo_keepalive() {
  # Prompt for the sudo password once, before build output floods the terminal.
  sudo -v

  # Background loop refreshes the sudo timestamp every 55 s so a long rebuild
  # does not prompt mid-build.  Dies when the parent exits.  I/O redirected to
  # /dev/null so that the background children do not hold stdout/stderr open
  # when the script is piped (which would cause the reader to hang).
  SCRIPT_PID=$$
  {
    while true; do
      sleep 55
      kill -0 "$SCRIPT_PID" 2>/dev/null || exit
      sudo -n true
    done
  } </dev/null >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!

  # check-suppress:suppression_doc: trap cleanup for sudo keepalive; subprocess may have already exited.
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT INT TERM
}

run_health_check() {
  _rhc_args=()
  if [ "$store_audit" = true ]; then
    _rhc_args+=(--store-audit)
  fi
  run_nix run "$REPO_ROOT/src#apply" health-check "${_rhc_args[@]}"
}

run_ai_sync() {
  # Call nucleus-ai sync to converge locally installed Ollama models with
  # the declarative manifest after the system configuration has been applied.
  if [ "$ai_sync" = false ]; then
    say -l ai "--no-ai-sync set; skipping post-apply model sync"
    return
  fi

  _ras_script="$REPO_ROOT/scripts/ai.sh"
  if [ ! -f "$_ras_script" ]; then
    say -l ai "scripts/ai.sh not found at $_ras_script; skipping model sync"
    return
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    say -l ai "ollama not found in PATH; skipping post-apply model sync"
    return
  fi

  say -l ai "running post-apply AI model sync..."
  apply_log_init
  if ! sh "$_ras_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l ai "ai.sh sync exited with an error; model sync incomplete (system apply succeeded)"
  fi
}

run_vm_post_apply() {
  _rvp_script="$REPO_ROOT/scripts/vm.sh"
  if [ ! -f "$_rvp_script" ]; then
    say -l nucleus-vm "scripts/vm.sh not found at $_rvp_script; skipping post-apply VM step"
    return
  fi

  if [ "$vm_setup" = true ]; then
    say -l nucleus-vm "running post-apply VM provisioning (setup)..."
    apply_log_init
    if ! sh "$_rvp_script" setup --accept-gsi-license 2>&1 | tee -a "$_apply_log"; then
      warn -l nucleus-vm "vm.sh setup exited with an error; VM setup incomplete (system apply succeeded)"
    fi
    return
  fi

  if [ "$vm_sync" = false ]; then
    say -l nucleus-vm "--no-vm-sync set; skipping post-apply VM config refresh"
    return
  fi

  say -l nucleus-vm "running post-apply VM config refresh (sync)..."
  apply_log_init
  if ! sh "$_rvp_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l nucleus-vm "vm.sh sync exited with an error; VM sync incomplete (system apply succeeded)"
  fi
}

# Per-run apply log: post-apply subcommand output (AI sync, replica sync, VM
# post-apply, GC) is teed here for audit while staying live on the console.
# Files land in the host user log dir (services.json $logging.logDir, honoring
# NUCLEUS_LOG_DIR) and are rotated by log-gc-user.sh.
_apply_log=""
apply_log_init() {
  if [ -z "$_apply_log" ]; then
    _ali_dir="$(nucleus_log_dir)"
    mkdir -p "$_ali_dir"
    _apply_log="$_ali_dir/apply-$(date -u +%Y%m%dT%H%M%SZ).log"
  fi
}

run_gc() {
  # Call scripts/gc.sh to perform bounded garbage collection after the system
  # configuration and model/VM setup have completed.
  _rgc_script="$REPO_ROOT/scripts/gc.sh"
  if [ ! -f "$_rgc_script" ]; then
    say -l gc "scripts/gc.sh not found at $_rgc_script; skipping garbage collection"
    return
  fi

  say -l gc "running post-apply garbage collection..."
  apply_log_init
  if ! sh "$_rgc_script" 2>&1 | tee -a "$_apply_log"; then
    warn -l gc "gc.sh exited with an error; GC incomplete (system apply succeeded)"
  fi
}

run_caddy_local_ca_trust() {
  # Delegate to src/scripts/services/caddy-trust.sh for Caddy local CA trust
  # (retry loop with caddy --address 127.0.0.1:2019).
  _rclct_script="$REPO_ROOT/src/scripts/services/caddy-trust.sh"
  if [ ! -f "$_rclct_script" ]; then
    say -l caddy-trust "caddy-trust.sh not found at $_rclct_script; skipping local CA trust"
    return
  fi

  if ! sh "$_rclct_script" "$1"; then
    warn -l caddy-trust 'delegated trust script exited with an error (continuing without failing apply)'
  fi
}

run_pin_flake_inputs() {
  # Build the flakeInputs output into a persistent profile so the daily GC
  # keeps flake-input *-source paths alive between applies (otherwise they are
  # re-fetched from cache.nixos.org on every apply).
  _rpfi_profile="/nix/var/nix/profiles/flake-inputs"
  say -l flake-inputs "pinning flake inputs to $_rpfi_profile..."
  if ! run_nix_as_root build --profile "$_rpfi_profile" "$REPO_ROOT/src#flakeInputs"; then
    warn -l flake-inputs "flakeInputs build failed (inputs may re-fetch next apply)"
  fi
}

run_replica_sync() {
  # Call scripts/cloud.sh sync so enabled replicas in users.json are
  # synchronized after a successful apply.
  if [ "$replica_sync" = false ]; then
    say -l replica-sync "skipping post-apply replica sync (default; pass --replica-sync to run now)"
    return
  fi

  _rrb_script="$REPO_ROOT/scripts/cloud.sh"
  if [ ! -f "$_rrb_script" ]; then
    say -l replica-sync "scripts/cloud.sh not found at $_rrb_script; skipping replica sync"
    return
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    say -l replica-sync "rclone not found in PATH; skipping post-apply replica sync"
    return
  fi

  say -l replica-sync "running post-apply replica sync..."
  apply_log_init
  if ! sh "$_rrb_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l replica-sync "cloud.sh sync exited with an error; replica sync incomplete (system apply succeeded)"
  fi
}

run_terminal_activations() {
  # Run activation commands that require the user's terminal TCC context
  # (macOS Full Disk Access / Accessibility), serialised by the
  # write-terminal-activations HM activation step to
  # $NUCLEUS_USER_ROOT/terminal-activations.list.
  #
  # This runs after the rebuild so the manifest exists, but before any
  # post-apply steps that may depend on the terminal-context changes.
  #
  # ── Policy ──────────────────────────────────────────────────────
  # This stage is a LAST RESORT for macOS TCC-sensitive commands only.
  # See src/modules/terminal-activations.nix for the full policy.
  # ─────────────────────────────────────────────────────────────────
  _rta_manifest="$NUCLEUS_USER_ROOT/terminal-activations.list"
  if [ ! -f "$_rta_manifest" ]; then
    return
  fi

  _rta_count=$(wc -l <"$_rta_manifest")
  if [ "$_rta_count" -eq 0 ]; then
    rm -f "$_rta_manifest"
    return
  fi

  # check-suppress:suppression_doc: grep returns exit code 1 when no lines match; set -e would abort.
  say -l terminal-activations "running $(grep -c '^[^#]' "$_rta_manifest" || true) terminal-context activation(s)..."
  while IFS= read -r _rta_line; do
    case "$_rta_line" in
    '' | '#'*) continue ;;
    esac
    say -l terminal-activations "$_rta_line"
    if ! eval "$_rta_line"; then
      warn -l terminal-activations "command exited with error (continuing)"
    fi
  done <"$_rta_manifest"
  rm -f "$_rta_manifest"
}

run_manual_display() {
  # Display the MANUAL.md for the given host after a successful apply.
  _rmd_host="$1"
  _rmd_manual="$REPO_ROOT/src/hosts/$_rmd_host/MANUAL.md"
  if [ ! -f "$_rmd_manual" ]; then
    return
  fi
  printf '\n'
  cat "$_rmd_manual"
  printf '\n'
}

case "$(uname -s)" in
Darwin)
  # nix-darwin manages both the system layer and the user Home Manager
  # profile.  darwin-rebuild invokes sudo internally for system activation.
  if [ -n "$target_user" ]; then
    say -l apply "--target-user is ignored on Darwin system rebuilds (host-level configuration selects the Home Manager user)."
  fi
  start_sudo_keepalive
  "$_ash_script_dir/secrets/generate-ssh-host-key.sh"
  "$_ash_script_dir/secrets/register-host-age-key.sh" --repo-root "$REPO_ROOT"
  run_health_check
  # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
  # while running as root (which otherwise produces ownership warnings).
  run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --impure --flake "$REPO_ROOT/src#MacBook"
  run_pin_flake_inputs
  run_terminal_activations
  "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
  run_caddy_local_ca_trust sudo
  NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/services/jellyfin-sync.sh"
  run_ai_sync
  run_replica_sync
  run_vm_post_apply
  run_manual_display MacBook
  ;;
Linux)
  if [ -f /etc/NIXOS ]; then
    # NixOS: use nixos-rebuild so the system layer and the embedded
    # home-manager module are applied in a single atomic activation.
    if [ -n "$target_user" ]; then
      say -l apply "--target-user is ignored on NixOS system rebuilds (host-level configuration selects the Home Manager user)."
    fi
    start_sudo_keepalive
    "$_ash_script_dir/secrets/generate-ssh-host-key.sh"
    "$_ash_script_dir/secrets/register-host-age-key.sh" --repo-root "$REPO_ROOT"
    run_health_check
    # Keep root invocations on root-owned HOME for consistent Nix behavior.
    run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#NixOS"
    run_pin_flake_inputs
    run_terminal_activations
    "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
    run_caddy_local_ca_trust sudo
    NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/services/jellyfin-sync.sh"
    run_ai_sync
    run_replica_sync
    run_vm_post_apply
    run_gc
    run_manual_display NixOS
  else
    # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
    # no sudo required — keepalive is not started.
    # The profile name must match the homeConfigurations key in flake.nix.
    target_username="${target_user:-${NUCLEUS_USERNAME:-$(id -un)}}"
    run_health_check
    run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
    run_pin_flake_inputs
    run_terminal_activations
    "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
    run_caddy_local_ca_trust user
    NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/services/jellyfin-sync.sh"
    run_ai_sync
    run_replica_sync
    run_vm_post_apply
    run_gc
    run_manual_display NixOS
  fi
  ;;
*)
  error "unsupported OS '$(uname -s)'"
  exit 1
  ;;
esac
