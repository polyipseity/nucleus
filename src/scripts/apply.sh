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

register_host_age_key_if_needed() {
  # Derive this machine's age public key from its SSH host public key and
  # register it in .sops.yaml as a new recipient, then rewrap every
  # SOPS-encrypted file so the machine can decrypt them on the first apply.
  #
  # Why run before darwin-rebuild / nixos-rebuild:
  #   deriveHostAgeKey (posix-sops.nix) writes /etc/sops/age/machine.txt
  #   only after the system activation completes.  On the first apply the
  #   machine key must already be a .sops.yaml recipient before sops-nix
  #   attempts to decrypt secrets.  The SSH host public key is created by
  #   the OS at install time and is available before any Nix activation.
  #
  # Idempotency: if the derived age public key is already present in
  #   .sops.yaml the function returns immediately (no file is modified).
  #
  # Prerequisites (before calling):
  #   - /etc/ssh/ssh_host_ed25519_key.pub must exist (OS-generated)
  #   - The primary GPG key must be in the keyring so sops updatekeys can
  #     re-encrypt data keys for all recipients including the new machine
  #   - ssh-to-age and sops must be on PATH (provided by mkApplyApp runtimeInputs)
  #   - .sops.yaml must contain the marker comment on its own line:
  #       "    # -- machine keys end; personal SSH backup key below --"
  _rak_host_pub="/etc/ssh/ssh_host_ed25519_key.pub"
  _rak_sops_yaml="$REPO_ROOT/.sops.yaml"

  if [ ! -f "$_rak_host_pub" ]; then
    printf 'nucleus: %s not found; skipping machine age key auto-registration.\n' \
      "$_rak_host_pub" >&2
    return
  fi

  # Derive the age public key from the SSH host public key (public-key
  # conversion; no passphrase or private key material is accessed).
  _rak_age_pub=""
  if ! _rak_age_pub="$(ssh-to-age -i "$_rak_host_pub")"; then
    printf 'nucleus: ERROR — ssh-to-age failed to derive age public key from %s.\n' \
      "$_rak_host_pub" >&2
    exit 1
  fi
  if [ -z "$_rak_age_pub" ]; then
    printf 'nucleus: ERROR — ssh-to-age returned an empty age public key for %s.\n' \
      "$_rak_host_pub" >&2
    exit 1
  fi

  # Idempotency: skip insertion and rewrap when this machine is already registered.
  if grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
    printf 'nucleus: machine age key already registered in .sops.yaml; skipping auto-registration.\n'
    return
  fi

  printf 'nucleus: registering machine age key in .sops.yaml and rewrapping SOPS files...\n'

  # Insert the new age key line immediately before the marker comment.
  # The marker delineates machine recipients from the personal SSH backup key
  # so new machines are always inserted above the backup entry.
  # A temp file is used so an interrupted write cannot corrupt .sops.yaml.
  _rak_tmp="$(mktemp)"
  awk -v age_pub="$_rak_age_pub" '
    /    # -- machine keys end; personal SSH backup key below --/ { print "    - " age_pub }
    { print }
  ' "$_rak_sops_yaml" > "$_rak_tmp"
  mv "$_rak_tmp" "$_rak_sops_yaml"

  # Verify the insertion succeeded; catches the case where the marker comment
  # was removed or mistyped.
  if ! grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
    printf 'nucleus: ERROR — failed to insert machine age key into .sops.yaml; is the marker comment present?\n' >&2
    exit 1
  fi

  # Rewrap all SOPS-encrypted files so the new machine recipient can decrypt
  # them.  Requires the primary GPG key in the keyring for re-encryption.
  # The --yes flag skips the interactive "update recipients" confirmation.
  for _rak_secret in \
      "$REPO_ROOT/src/secrets/git-identities.yml" \
      "$REPO_ROOT/src/secrets/gpg-personal.yml" \
      "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    if ! sops updatekeys --yes "$_rak_secret"; then
      printf 'nucleus: ERROR — sops updatekeys failed for %s.\n' "$_rak_secret" >&2
      printf 'nucleus: Ensure the primary GPG key is imported first:\n' >&2
      printf 'nucleus:   gpg --import <backup-key-file>\n' >&2
      exit 1
    fi
  done

  # Rewrap wallpaper blobs (enumerated at runtime; count is unknown at script
  # parse time).  Read from a temp-file list rather than a pipe so that a
  # `sops updatekeys` failure exits the outer script via set -eu; exit 1
  # inside a pipe subshell would be silently swallowed.
  if [ -d "$REPO_ROOT/src/assets/wallpapers" ]; then
    _rak_wallpaper_list="$(mktemp)"
    find "$REPO_ROOT/src/assets/wallpapers" -name "*.sops" -type f \
      > "$_rak_wallpaper_list"
    while IFS= read -r _rak_wallpaper; do
      if ! sops updatekeys --yes "$_rak_wallpaper"; then
        # Temp file is not explicitly removed here because exit 1 terminates
        # the script immediately; the OS reclaims /tmp files on reboot.
        # Removing it inside the read-loop body would trigger SC2094 (the
        # same variable appears in both `rm` and `done < file`).
        printf 'nucleus: ERROR — sops updatekeys failed for %s.\n' "$_rak_wallpaper" >&2
        printf 'nucleus: Ensure the primary GPG key is imported first:\n' >&2
        printf 'nucleus:   gpg --import <backup-key-file>\n' >&2
        exit 1
      fi
    done < "$_rak_wallpaper_list"
    rm -f "$_rak_wallpaper_list"
  fi

  printf 'nucleus: machine age key registered and SOPS files rewrapped.\n'
  printf 'nucleus: Commit the changes before deploying to other machines:\n'
  printf 'nucleus:   git add .sops.yaml src/secrets src/assets/wallpapers\n'
  printf 'nucleus:   git commit -m "chore: register <hostname> machine age key"\n'
}

case "$(uname -s)" in
  Darwin)
    # nix-darwin manages both the system layer and the user Home Manager
    # profile.  darwin-rebuild invokes sudo internally for system activation.
    start_sudo_keepalive
    register_host_age_key_if_needed
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
      register_host_age_key_if_needed
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
