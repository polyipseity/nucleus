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
# nix binary.  nix-command and flakes features are passed explicitly so the
# script works even when they are not pre-enabled in nix.conf.
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
# Pass experimental features at every nix invocation rather than relying on
# nix.conf so the script is portable to freshly bootstrapped machines where
# the system config has not yet been applied.
NIX_EXTRA_FEATURES="nix-command flakes"

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
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    sudo -H nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      start_sudo_keepalive
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      sudo -H nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
      # no sudo required — keepalive is not started.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${NUCLEUS_USERNAME:-$(id -un)}"
      nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
