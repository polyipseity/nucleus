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
# After the main apply command succeeds, scripts/ai-sync.sh is called to
# converge locally installed Ollama models with the declarative manifest.
# Pass --skip-ai-sync to suppress the model sync step — useful in CI or on
# low-bandwidth connections where model pulls (2–20 GB each) are undesirable.
#
# Arguments:
#   --skip-ai-sync  skip the post-apply Ollama model sync step
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
# Flag parsing
# ---------------------------------------------------------------------------
skip_ai_sync=false

for _arg in "$@"; do
  case "$_arg" in
    --skip-ai-sync)
      # Model pulls are 2–20 GB and may be undesirable in CI or on
      # low-bandwidth connections; this flag opts out of the post-apply sync.
      skip_ai_sync=true
      ;;
    *)
      printf '%s\n' "apply: unsupported argument '$_arg'" >&2
      exit 1
      ;;
  esac
done

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
  # Why resolve from REPO_ROOT rather than $SCRIPT_DIR:
  #   When running via `nix run .#apply`, $SCRIPT_DIR points into the Nix
  #   store where scripts/ai-sync.sh does not exist.  REPO_ROOT is derived
  #   from `git rev-parse --show-toplevel` and always refers to the live
  #   working tree.
  #
  # Why detect ollama from $PATH rather than adding it to runtimeInputs:
  #   ollama is a user-installed daemon managed declaratively by the AI
  #   module (src/modules/ai/default.nix and hosts/nixos/ai.nix).  Bundling
  #   it in runtimeInputs would create a second, potentially different binary
  #   that could mismatch the running server's version.  PATH detection keeps
  #   the sync aligned with the actual runtime binary.
  if [ "$skip_ai_sync" = true ]; then
    printf '%s\n' "nucleus: --skip-ai-sync set; skipping post-apply model sync"
    return
  fi

  _ras_script="$REPO_ROOT/scripts/ai-sync.sh"
  if [ ! -f "$_ras_script" ]; then
    printf '%s\n' "nucleus: scripts/ai-sync.sh not found at $_ras_script; skipping model sync"
    return
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    printf '%s\n' "nucleus: ollama not found in PATH; skipping post-apply model sync"
    return
  fi

  printf '%s\n' "nucleus: running post-apply AI model sync..."
  if ! sh "$_ras_script"; then
    printf '%s\n' "nucleus: ai-sync.sh exited with an error; model sync incomplete (system apply succeeded)" >&2
  fi
}

generate_ssh_host_key_if_needed() {
  # Ensure /etc/ssh/ssh_host_ed25519_key exists before
  # register_host_age_key_if_needed tries to derive the machine age public key
  # from it.  On freshly provisioned machines the OS may not have generated host
  # keys yet; ssh-keygen -A creates all standard host key types without
  # overwriting any that already exist, making this call idempotent.
  #
  # Why before register_host_age_key_if_needed:
  #   register_host_age_key_if_needed derives the machine age public key from
  #   /etc/ssh/ssh_host_ed25519_key.pub.  If the key does not exist it skips
  #   registration silently, so the machine can never decrypt its own SOPS
  #   secrets until the operator re-runs apply after the OS has generated the
  #   key.  Generating it here makes first-apply fully self-contained.
  #
  # Requires: sudo session already acquired (start_sudo_keepalive must have
  #   been called before this function).
  # PATH: ssh-keygen is provided by openssh in mkApplyApp runtimeInputs.
  #   The sudo invocation carries PATH explicitly so the Nix-wrapped binary
  #   is found even after sudo resets the environment.
  _gsk_host_key="/etc/ssh/ssh_host_ed25519_key"

  if [ -f "$_gsk_host_key" ]; then
    return
  fi

  printf 'nucleus: %s not found; generating SSH host keys...\n' "$_gsk_host_key"
  # Pass PATH explicitly so sudo finds the Nix openssh ssh-keygen rather than
  # any older system ssh-keygen that may be shadowed by runtimeInputs.
  if ! sudo env "PATH=$PATH" ssh-keygen -A; then
    printf 'nucleus: ERROR — ssh-keygen -A failed; cannot generate SSH host keys.\n' >&2
    exit 1
  fi

  if [ ! -f "$_gsk_host_key" ]; then
    printf 'nucleus: ERROR — ssh-keygen -A completed but %s is still absent.\n' \
      "$_gsk_host_key" >&2
    exit 1
  fi

  printf 'nucleus: SSH host keys generated successfully.\n'
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
    generate_ssh_host_key_if_needed
    register_host_age_key_if_needed
    run_nix run "$REPO_ROOT/src#health-check"
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    run_ai_sync
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      start_sudo_keepalive
      generate_ssh_host_key_if_needed
      register_host_age_key_if_needed
      run_nix run "$REPO_ROOT/src#health-check"
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      run_ai_sync
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
      # no sudo required — keepalive is not started.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${NUCLEUS_USERNAME:-$(id -un)}"
      run_nix run "$REPO_ROOT/src#health-check"
      run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      run_ai_sync
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
