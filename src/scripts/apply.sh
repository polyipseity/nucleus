#!/usr/bin/env sh
# src/scripts/apply.sh — Dispatch the Nix apply command for the current host.
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
# Environment variables:
#   NUCLEUS_USERNAME — override the Home Manager profile name used on standalone
#                      Linux.  Defaults to `id -un` (the current user).  Set
#                      this when the local username differs from the key used
#                      in homeConfigurations in flake.nix.
#
# Prerequisites: Nix installed; caller's environment must allow reaching the
# nix binary.
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
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
  NIX_CONFIG="$(merge_nix_config)" nix "$@"
}

run_nix_as_root() {
  # Execute nix as root while injecting the merged config explicitly so sudo's
  # default environment filtering cannot drop required flake settings.
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env "NIX_CONFIG=$NIX_CONFIG_VALUE" nix "$@"
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
  SCRIPT_PID=$$
  while true; do
    sleep 55
    kill -0 "$SCRIPT_PID" 2>/dev/null || exit
    sudo -n true
  done &
  SUDO_KEEPALIVE_PID=$!

  # Kill the keepalive on any exit (success, error, INT, or TERM) so no
  # background job is leaked to the calling shell.
  # shellcheck disable=SC2064  # intentional: expand PID now, not at trap time
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT INT TERM
}

case "$(uname -s)" in
  Darwin)
    # nix-darwin manages both the system layer and the user Home Manager
    # profile.  darwin-rebuild invokes sudo internally for system activation.
    start_sudo_keepalive
    run_nix run "$REPO_ROOT/src#health-check"
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      start_sudo_keepalive
      run_nix run "$REPO_ROOT/src#health-check"
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
      # no sudo required — keepalive is not started.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${NUCLEUS_USERNAME:-$(id -un)}"
      run_nix run "$REPO_ROOT/src#health-check"
      run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
