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

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

# Usage
usage() {
  usage_std 'apply.sh' '[--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--target-user=<name>] [--username=<name>] [--vm-setup|--no-vm-setup]' \
    'Dispatch the Nix apply command for the current host.'
  exit 0
}

# Flag parsing
ai_sync=true
replica_sync=false
vm_setup=false
target_user=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ai-sync) ai_sync=true ;;
    --no-ai-sync) ai_sync=false ;;
    --replica-sync) replica_sync=true ;;
    --no-replica-sync) replica_sync=false ;;
    --vm-setup) vm_setup=true ;;
    --no-vm-setup) vm_setup=false ;;
    --target-user)
      target_user="$2"; shift
      if [ -z "$target_user" ]; then
        printf '%s\n' "apply: --target-user requires a non-empty value" >&2
        exit 1
      fi
      ;;
    --target-user=*)
      target_user="${1#--target-user=}"
      if [ -z "$target_user" ]; then
        printf '%s\n' "apply: --target-user requires a non-empty value" >&2
        exit 1
      fi
      ;;
    --username)
      NUCLEUS_USERNAME="$2"
      shift
      if [ -z "$NUCLEUS_USERNAME" ]; then
        printf '%s\n' "apply: --username requires a non-empty value" >&2
        exit 1
      fi
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf '%s\n' "apply: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

REPO_ROOT="$(derive_repo_root)"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

# Augment PATH with the user Nix profile bin directory so Nix-managed binaries
# (e.g. ssh-to-age, sops) are available when the script is invoked directly
# rather than through `nix run .#apply` (which adds them via runtimeInputs).
# The guard avoids redundant PATH modifications when already present.
_nix_profile_bin="$HOME/.nix-profile/bin"
case ":$PATH:" in
  *":$_nix_profile_bin:"*) ;;
  *)
    if [ -d "$_nix_profile_bin" ]; then
      PATH="$_nix_profile_bin:$PATH"
      export PATH
    fi
    ;;
esac
unset _nix_profile_bin

# Resolve src/scripts/ for apply-internal script delegation.
_ash_script_dir="$(cd "$(dirname -- "$0")" && pwd -P)"

# Symlink the LiteLLM config so edits take effect on service restart without
# re-running apply.  All host services (macOS launchd, NixOS systemd, Windows
# scheduled task) reference this well-known path.
mkdir -p "$HOME/.config/nucleus"
ln -sf "$REPO_ROOT/src/modules/ai/litellm-config.yml" "$HOME/.config/nucleus/litellm-config.yml"

run_nix() {
  NIX_CONFIG="$(merge_nix_config)" nix --option warn-dirty false "$@"
}

run_nix_as_root() {
  # Forward NUCLEUS_REPO_ROOT so builtins.getEnv in Nix config can construct
  # writable out-of-store symlinks during evaluation.
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env "NIX_CONFIG=$NIX_CONFIG_VALUE" "NUCLEUS_REPO_ROOT=${NUCLEUS_REPO_ROOT}" nix --option warn-dirty false "$@"
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

  # shellcheck disable=SC2064  # intentional: expand PID now, not at trap time
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT INT TERM
}

run_ai_sync() {
  # Call scripts/ai-sync.sh to converge locally installed Ollama models with
  # the declarative manifest after the system configuration has been applied.
  if [ "$ai_sync" = false ]; then
    printf '%s\n' "ai-sync: --no-ai-sync set; skipping post-apply model sync"
    return
  fi

  if ! command -v nucleus-ai-sync >/dev/null 2>&1; then
    printf '%s\n' "ai-sync: nucleus-ai-sync not found in PATH; skipping model sync"
    return
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    printf '%s\n' "ai-sync: ollama not found in PATH; skipping post-apply model sync"
    return
  fi

  printf '%s\n' "ai-sync: running post-apply AI model sync..."
  if ! nucleus-ai-sync; then
    printf '%s\n' "ai-sync: nucleus-ai-sync exited with an error; model sync incomplete (system apply succeeded)" >&2
  fi
}

run_vm_setup() {
  # Call scripts/vm-setup.sh to provision virtual machine disk images and
  # register VMs after the system configuration has been applied.
  if [ "$vm_setup" = false ]; then
    printf '%s\n' "vm-setup: --vm-setup not set; skipping post-apply VM provisioning"
    return
  fi

  if ! command -v nucleus-vm-setup >/dev/null 2>&1; then
    printf '%s\n' "vm-setup: nucleus-vm-setup not found in PATH; skipping VM setup"
    return
  fi

  printf '%s\n' "vm-setup: running post-apply VM provisioning..."
  if ! nucleus-vm-setup; then
    printf '%s\n' "vm-setup: nucleus-vm-setup exited with an error; VM setup incomplete (system apply succeeded)" >&2
  fi
}

run_gc() {
  # Call scripts/gc.sh to perform bounded garbage collection after the system
  # configuration and model/VM setup have completed.
  _rgc_script="$REPO_ROOT/scripts/gc.sh"
  if [ ! -f "$_rgc_script" ]; then
    printf '%s\n' "gc: scripts/gc.sh not found at $_rgc_script; skipping garbage collection"
    return
  fi

  printf '%s\n' "gc: running post-apply garbage collection..."
  if ! sh "$_rgc_script"; then
    printf '%s\n' "gc: gc.sh exited with an error; GC incomplete (system apply succeeded)" >&2
  fi
}

run_caddy_local_ca_trust() {
  # Delegate to src/scripts/caddy-trust.sh for Caddy local CA trust
  # (retry loop with caddy --address 127.0.0.1:2019).
  _rclct_script="$REPO_ROOT/src/scripts/caddy-trust.sh"
  if [ ! -f "$_rclct_script" ]; then
    printf '%s\n' "caddy-trust: caddy-trust.sh not found at $_rclct_script; skipping local CA trust"
    return
  fi

  if ! sh "$_rclct_script" "$1"; then
    printf '%s\n' 'caddy-trust: delegated trust script exited with an error (continuing without failing apply)' >&2
  fi
}

run_replica_sync() {
  # Call scripts/replica-sync.sh so enabled replicas in users.json are
  # synchronized after a successful apply.
  if [ "$replica_sync" = false ]; then
    printf '%s\n' "replica-sync: skipping post-apply replica sync (default; pass --replica-sync to run now)"
    return
  fi

  _rrb_script="$REPO_ROOT/scripts/replica-sync.sh"
  if [ ! -f "$_rrb_script" ]; then
    printf '%s\n' "replica-sync: scripts/replica-sync.sh not found at $_rrb_script; skipping replica sync"
    return
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    printf '%s\n' "replica-sync: rclone not found in PATH; skipping post-apply replica sync"
    return
  fi

  printf '%s\n' "replica-sync: running post-apply replica sync..."
  if ! sh "$_rrb_script"; then
    printf '%s\n' "replica-sync: replica-sync.sh exited with an error; replica sync incomplete (system apply succeeded)" >&2
  fi
}

case "$(uname -s)" in
  Darwin)
    # nix-darwin manages both the system layer and the user Home Manager
    # profile.  darwin-rebuild invokes sudo internally for system activation.
    if [ -n "$target_user" ]; then
      printf '%s\n' "apply: --target-user is ignored on Darwin system rebuilds (host-level configuration selects the Home Manager user)."
    fi
    start_sudo_keepalive
    "$_ash_script_dir/generate-ssh-host-key.sh"
    "$_ash_script_dir/register-host-age-key.sh" --repo-root "$REPO_ROOT"
    run_nix run "$REPO_ROOT/src#health-check"
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --impure --flake "$REPO_ROOT/src#macbook"
    "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
    run_caddy_local_ca_trust sudo
    NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/jellyfin-sync.sh"
    run_ai_sync
    run_replica_sync
    run_vm_setup
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      if [ -n "$target_user" ]; then
        printf '%s\n' "apply: --target-user is ignored on NixOS system rebuilds (host-level configuration selects the Home Manager user)."
      fi
      start_sudo_keepalive
      "$_ash_script_dir/generate-ssh-host-key.sh"
      "$_ash_script_dir/register-host-age-key.sh" --repo-root "$REPO_ROOT"
      run_nix run "$REPO_ROOT/src#health-check"
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
      run_caddy_local_ca_trust sudo
      NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/jellyfin-sync.sh"
      run_ai_sync
      run_replica_sync
      run_vm_setup
      run_gc
      run_gc
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
      # no sudo required — keepalive is not started.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${target_user:-${NUCLEUS_USERNAME:-$(id -un)}}"
      run_nix run "$REPO_ROOT/src#health-check"
      run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
      run_caddy_local_ca_trust user
      NUCLEUS_REPO_ROOT="$REPO_ROOT" sh "$REPO_ROOT/src/scripts/jellyfin-sync.sh"
      run_ai_sync
      run_replica_sync
      run_vm_setup
      run_gc
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
