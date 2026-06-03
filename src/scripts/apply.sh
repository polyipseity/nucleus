#!/usr/bin/env sh
# src/scripts/apply.sh — Dispatch the Nix apply command for the current host.
#
# This is a thin orchestrator: OS detection, lifecycle ordering
# (pre-apply checks → rebuild → post-apply provisioning), and
# error-boundary handling. All heavy logic lives in dedicated sibling scripts
# so each concern can be validated, tested, and reused independently.
#
# Script location convention:
#   scripts/        — Cross-platform scripts consumed as flake apps via
#                     writeShellApplication (ai-sync, vm-setup) or as repo
#                     script inputs (gc, replica-sync, and others).
#   src/scripts/    — Apply-only internal scripts executed by this dispatcher
#                     only.  Resolved at runtime via $_ash_script_dir.
#
# Pre-apply lifecycle (order is significant):
#   1. SSH host key generation             (generate-ssh-host-key.sh)
#   2. SOPS machine key registration       (register-host-age-key.sh)
#   3. Nix health check                    (nix run .#health-check)
#   4. System rebuild                      (darwin-rebuild / nixos-rebuild / home-manager)
#   5. Prek hooks installation             (install-prek-hooks.sh)
#
# Post-apply provisioning order:
#   1. Local CA trust                      (caddy-trust.sh)
#   2. Jellyfin sync                       (jellyfin-sync.sh)
#   3. AI model sync                       (ai-sync.sh)
#   4. Cloud replica sync                  (replica-sync.sh)
#   5. VM setup                            (vm-setup.sh)
#   6. Garbage collection                  (gc.sh)
#
# Detects the operating system and invokes the appropriate flake output:
#   Darwin  → darwin-rebuild switch  (nix-darwin; manages system + home-manager)
#   NixOS   → nixos-rebuild switch   (requires sudo; detected via /etc/NIXOS)
#   Linux   → home-manager switch    (standalone HM for plain Linux / WSL)
#
# For Darwin and NixOS, the script prompts for the sudo password once upfront
# via `sudo -v`, then maintains the sudo session with a background keepalive
# loop for the duration of the rebuild (which can take many minutes).
# Standalone Linux (plain Linux / WSL) runs home-manager without sudo and
# skips the keepalive entirely.
#
# After the main apply command succeeds, scripts/ai-sync.sh is called to
# converge locally installed Ollama models with the declarative manifest.
# Pass --no-ai-sync to suppress the model sync step — useful in CI or on
# low-bandwidth connections where model pulls (2–20 GB each) are undesirable.
#
# Arguments:
#   --ai-sync|--no-ai-sync    control the post-apply Ollama model sync step
#   --replica-sync|--no-replica-sync  control the post-apply cloud replica sync step
#   --vm-setup|--no-vm-setup  control the post-apply VM setup step
#   --target-user   select the Home Manager flake profile key on standalone
#                   Linux hosts (ignored on Darwin and NixOS system rebuilds)
#
# Environment variables:
#   NUCLEUS_USERNAME — override the Home Manager profile name used on standalone
#                      Linux.  Defaults to `id -un` (the current user).  Set
#                      this when the local username differs from the key used
#                      in homeConfigurations in flake.nix.
#
# Prerequisites: Nix installed; caller's environment must allow reaching the
# nix binary.
set -eu

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE_EOF'
Usage: apply.sh [--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--vm-setup|--no-vm-setup] [--target-user=<name>]

Dispatch the Nix apply command for the current host.

Options:
  -h, --help            Show this help message and exit
  --ai-sync             Run the post-apply Ollama model sync step (default)
  --no-ai-sync          Skip the post-apply Ollama model sync step
  --replica-sync        Run the post-apply cloud replica sync step (opt-in)
  --no-replica-sync     Skip the post-apply cloud replica sync step
  --vm-setup            Run the post-apply VM setup step (opt-in)
  --no-vm-setup         Skip the post-apply VM setup step
  --target-user      Select the Home Manager flake profile key on standalone
                     Linux hosts (ignored on Darwin and NixOS system rebuilds)
USAGE_EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
ai_sync=true
replica_sync=false
vm_setup=false
target_user=""
_aas_expect_target_user=false

for _arg in "$@"; do
  if [ "$_aas_expect_target_user" = true ]; then
    if [ -z "$_arg" ]; then
      printf '%s\n' "apply: --target-user requires a non-empty value" >&2
      exit 1
    fi
    target_user="$_arg"
    _aas_expect_target_user=false
    continue
  fi

  case "$_arg" in
    --ai-sync)
      # Model pulls are 2–20 GB and may be undesirable in CI or on
      # low-bandwidth connections; this flag opts in to the post-apply sync.
      ai_sync=true
      ;;
    --no-ai-sync)
      # Model pulls are 2–20 GB and may be undesirable in CI or on
      # low-bandwidth connections; this flag opts out of the post-apply sync.
      ai_sync=false
      ;;
    --replica-sync)
      # Replica sync is slow for large trees and skipped by default after
      # apply; this flag opts in to immediate post-apply convergence.
      replica_sync=true
      ;;
    --no-replica-sync)
      # Replica sync is slow for large trees and skipped by default after
      # apply; this flag opts out of immediate post-apply convergence.
      replica_sync=false
      ;;
    --vm-setup)
      # VM setup provisions QEMU disk images and registers VMs (UTM on macOS,
      # libvirt on NixOS).  Skipped by default after apply because disk
      # pre-allocation and VM registration are large, slow, and idempotent.
      vm_setup=true
      ;;
    --no-vm-setup)
      # VM setup provisions QEMU disk images and registers VMs (UTM on macOS,
      # libvirt on NixOS).  Skipped by default after apply because disk
      # pre-allocation and VM registration are large, slow, and idempotent.
      vm_setup=false
      ;;
    --target-user)
      _aas_expect_target_user=true
      ;;
    --target-user=*)
      target_user="${_arg#--target-user=}"
      if [ -z "$target_user" ]; then
        printf '%s\n' "apply: --target-user requires a non-empty value" >&2
        exit 1
      fi
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf '%s\n' "apply: unsupported argument '$_arg'" >&2
      exit 1
      ;;
  esac
done

if [ "$_aas_expect_target_user" = true ]; then
  printf '%s\n' "apply: --target-user requires a value" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

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

# Write the repo root to a well-known path so Home Manager activation scripts
# (particularly vscodeSymlinks in editors.nix) can locate live repo files such
# as src/modules/configs/vscode/.  Environment variables are not reliably
# propagated through the sudo sessions that darwin-rebuild and nixos-rebuild
# invoke, so a stable file path is the safe transport mechanism.
mkdir -p "$HOME/.config/nucleus"
printf '%s\n' "$REPO_ROOT" > "$HOME/.config/nucleus/repo-root"

# Keep one centralized Nix config fragment for this script so every `nix` call
# gets flake support without repeating CLI flags.
NIX_FEATURES_CONFIG="experimental-features = nix-command flakes"

merge_nix_config() {
  # Merge caller-provided NIX_CONFIG (if any) with the required flake features
  # so user-level overrides remain intact while the apply flow stays portable.
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$NIX_FEATURES_CONFIG"
  else
    printf '%s' "$NIX_FEATURES_CONFIG"
  fi
}

run_nix() {
  # Execute nix with the merged config for non-root operations.
  # Suppress repeated dirty-tree warnings so apply logs highlight actionable
  # warnings/errors instead of repeating VCS status lines.
  NIX_CONFIG="$(merge_nix_config)" nix --option warn-dirty false "$@"
}

run_nix_as_root() {
  # Execute nix as root while injecting the merged config explicitly so sudo's
  # default environment filtering cannot drop required flake settings.
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env "NIX_CONFIG=$NIX_CONFIG_VALUE" nix --option warn-dirty false "$@"
}

start_sudo_keepalive() {
  # Prompt for the sudo password once, before build output floods the terminal.
  # sudo -v validates (and refreshes) credentials without running any
  # privileged command yet.
  sudo -v

  # Keep the sudo timestamp alive for the duration of the rebuild.
  # darwin-rebuild and nixos-rebuild switch can run for many minutes;
  # the timestamp_timeout=5 set in posix-security.nix would expire mid-build
  # and block on a password prompt buried in build output.
  #
  # SCRIPT_PID is captured before the & fork because $$ is
  # implementation-defined inside a background subshell in POSIX sh —
  # capturing it here guarantees the parent's PID is used.
  #
  # Loop: sleep first (timestamp was just refreshed by sudo -v), then check
  # the parent is still alive before touching sudo, then refresh.
  # kill -0 sends no signal; it just tests whether the PID exists.
  #
  # The compound command is redirected to /dev/null so that the background
  # subshell and its children (sleep, sudo) do not inherit this script's
  # stdout/stderr file descriptors.  Without this redirect, when the script is
  # run with stdout connected to a pipe (e.g. a CI step or a tool call), the
  # pipe reader blocks until every process holding the write end closes it.
  # In non-interactive mode a shell receiving SIGTERM exits immediately but
  # does NOT kill its foreground child (the sleep); that orphaned sleep holds
  # the write end open for up to 55 s after the main script has already exited,
  # making the caller appear hung.  In a terminal stdout is a TTY — no pipe,
  # no hang — so the problem is invisible outside automated contexts.
  # sudo -n true failures are benign (session may expire mid-build; the loop
  # simply retries on the next iteration); suppression here is intentional.
  SCRIPT_PID=$$
  {
    while true; do
      sleep 55
      kill -0 "$SCRIPT_PID" 2>/dev/null || exit
      sudo -n true
    done
  } </dev/null >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!

  # Kill the keepalive on any exit (success, error, INT, or TERM) so no
  # background job is leaked to the calling shell.
  # shellcheck disable=SC2064  # intentional: expand PID now, not at trap time
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT INT TERM
}

run_ai_sync() {
  # Call scripts/ai-sync.sh to converge locally installed Ollama models with
  # the declarative manifest after the system configuration has been applied.
  #
  # Why post-apply rather than pre-apply:
  #   Model pulls are 2–20 GB; running them before activation could block the
  #   critical configuration path.  Post-apply makes sync a best-effort step
  #   that does not gate the system coming up.
  #
  # Why best-effort (no hard failure):
  #   The system configuration applied successfully.  Model sync is additive —
  #   a missing model does not break any declared system state.  Treating a
  #   sync failure as fatal would roll back a successful system apply.
  #
  # Why detect ollama from $PATH rather than adding it to runtimeInputs:
  #   ollama is a user-installed daemon managed declaratively by the AI
  #   module (src/modules/ai/default.nix and hosts/NixOS/ai.nix).  Bundling
  #   it in runtimeInputs would create a second, potentially different binary
  #   that could mismatch the running server's version.  PATH detection keeps
  #   the sync aligned with the actual runtime binary.
  #
  # Why lookup nucleus-ai-sync from $PATH rather than REPO_ROOT:
  #   When running via `nix run .#apply`, the nucleus-ai-sync command is
  #   bundled into the app closure via siblingScripts in mkApplyApp.  The
  #   script's runtimeInputs (jq) are resolved at build time, so apply.sh
  #   does not need to know the repository layout.
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
  #
  # Why opt-in (--vm-setup|--no-vm-setup):
  #   Disk pre-allocation is slow (up to 128 GB) and only needed on the first
  #   provision of a new machine.  Subsequent applies do not re-create existing
  #   disks; the guard is in the script itself.  Still, running it on every
  #   apply would waste time for users who never need it.
  #
  # Why best-effort:
  #   A VM disk or registration error should not retroactively fail a completed
  #   system apply.
  #
  # Why lookup nucleus-vm-setup from $PATH rather than REPO_ROOT:
  #   When running via `nix run .#apply`, the nucleus-vm-setup command is
  #   bundled into the app closure via siblingScripts in mkApplyApp.  The
  #   script's runtimeInputs (jq) are resolved at build time, so apply.sh
  #   does not need to know the repository layout.
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
  #
  # Why post-apply:
  #   Build outputs, caches, and stale artifacts accumulate during updates.
  #   GC after all provisioning steps ensures the cleanup pass sees the most
  #   recent set of intended resources.
  #
  # Why best-effort:
  #   The system configuration and all provisioning steps have succeeded.
  #   GC failures should not retroactively fail a completed apply.
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
  #
  # Why a separate file:
  #   The extracted script can be validated independently (shellcheck),
  #   called from multiple privilege contexts (sudo/user), and reused
  #   outside apply.sh if needed.
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
  # synchronized after a successful apply. This keeps local replica trees
  # (for example iCloudReplica) populated without requiring a separate manual run.
  #
  # Why best-effort: replica convergence is additive and may involve large
  # transfers. A replica error should not retroactively fail a completed
  # system apply.
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
    "$_ash_script_dir/register-host-age-key.sh" "$REPO_ROOT"
    run_nix run "$REPO_ROOT/src#health-check"
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    "$_ash_script_dir/install-prek-hooks.sh" "$REPO_ROOT"
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
      "$_ash_script_dir/register-host-age-key.sh" "$REPO_ROOT"
      run_nix run "$REPO_ROOT/src#health-check"
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      "$_ash_script_dir/install-prek-hooks.sh" "$REPO_ROOT"
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
      "$_ash_script_dir/install-prek-hooks.sh" "$REPO_ROOT"
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
