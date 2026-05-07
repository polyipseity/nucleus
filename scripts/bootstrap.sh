#!/usr/bin/env sh
# Install Nix (if absent) and the Nix-managed bootstrap dependencies.
# After running this script, apply the configuration with: nix run ./src#apply
#
# Commands:
#   install-deps  Install bootstrap dependencies only (default)
#   apply         Install bootstrap dependencies, then run the src apply flow
#
# Options:
#   --skip-ai-sync  Pass through to nix run .#apply; suppresses the post-apply
#                   Ollama model sync step.  Useful in CI or on low-bandwidth
#                   connections where model pulls (2–20 GB) are undesirable.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
VERSIONS_FILE="$SCRIPT_DIR/bootstrap-versions.env"
COMMAND="${1:-install-deps}"
NIX_FEATURES_CONFIG="experimental-features = nix-command flakes"

# ---------------------------------------------------------------------------
# Flag parsing — collect extra flags to pass through to apply
# ---------------------------------------------------------------------------
skip_ai_sync=false
# Shift past the command positional arg before scanning remaining args.
# If no command arg was given, $# is 0 and the loop is a no-op.
_bsh_remaining_args=""
_bsh_first=true
for _bsh_arg in "$@"; do
  # Skip the first argument (the command word) so subsequent flags are parsed.
  if [ "$_bsh_first" = true ]; then
    _bsh_first=false
    continue
  fi
  case "$_bsh_arg" in
    --skip-ai-sync)
      # Model pulls are 2–20 GB; suppress post-apply sync in CI or on
      # low-bandwidth connections.
      skip_ai_sync=true
      ;;
    *)
      printf '%s\n' "error: unsupported argument '$_bsh_arg'" >&2
      exit 1
      ;;
  esac
done

merge_nix_config() {
  # Merge caller-provided NIX_CONFIG (if any) with required flake settings so
  # bootstrap commands stay portable without repeating feature flags.
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$NIX_FEATURES_CONFIG"
  else
    printf '%s' "$NIX_FEATURES_CONFIG"
  fi
}

run_nix() {
  # Execute nix with the merged config for this script invocation.
  NIX_CONFIG="$(merge_nix_config)" nix "$@"
}

if [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ] || [ "$COMMAND" = "help" ]; then
  cat <<'EOF'
Usage: bootstrap.sh [install-deps|apply] [--skip-ai-sync]

Installs Nix (if absent) and the Nix-managed bootstrap dependencies
(gnupg, sops, ssh-to-age) for this host.

Commands:
  install-deps  Install bootstrap dependencies only (default)
  apply         Install bootstrap dependencies, then run src apply flow

Options:
  --skip-ai-sync  Suppress the post-apply Ollama model sync step.  Useful in
                  CI or on low-bandwidth connections where model pulls
                  (2–20 GB each) are undesirable.
  -h, --help    Show this help message
EOF
  exit 0
fi

if [ "$COMMAND" != "apply" ] && [ "$COMMAND" != "install-deps" ]; then
  printf '%s\n' "error: unsupported command '$COMMAND' (supported: apply, install-deps)" >&2
  exit 1
fi

load_bootstrap_versions() {
  # Dot-sources bootstrap-versions.env into the current shell with `set -a`
  # (auto-export) so every variable defined in the file is exported and
  # available to child processes such as the Nix installer.
  #
  # Validates that the two mandatory variables NUCLEUS_NIX_INSTALLER_SHA256
  # and NUCLEUS_NIX_INSTALLER_URL are both present and non-empty; exits 1 with
  # a descriptive error if either is missing.
  #
  # Outputs (exported shell variables):
  #   NIX_INSTALLER_SHA256  — expected SHA-256 hex digest of the installer
  #   NIX_INSTALLER_URL     — download URL for the Nix installer script
  if [ ! -f "$VERSIONS_FILE" ]; then
    printf '%s\n' "error: expected bootstrap versions file at $VERSIONS_FILE" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "$VERSIONS_FILE"
  set +a

  if [ -z "${NUCLEUS_NIX_INSTALLER_SHA256:-}" ]; then
    printf '%s\n' "error: NUCLEUS_NIX_INSTALLER_SHA256 missing in $VERSIONS_FILE" >&2
    exit 1
  fi

  if [ -z "${NUCLEUS_NIX_INSTALLER_URL:-}" ]; then
    printf '%s\n' "error: NUCLEUS_NIX_INSTALLER_URL missing in $VERSIONS_FILE" >&2
    exit 1
  fi

  NIX_INSTALLER_SHA256="$NUCLEUS_NIX_INSTALLER_SHA256"
  NIX_INSTALLER_URL="$NUCLEUS_NIX_INSTALLER_URL"
}

bootstrap_nix_if_missing() {
  # Installs Nix via the official installer script when `nix` is not already
  # present in PATH.  No-op if Nix is already installed.
  #
  # Steps:
  #   1. Download the installer from NIX_INSTALLER_URL to a temp file.
  #   2. Verify the SHA-256 digest against NIX_INSTALLER_SHA256 (unless the
  #      placeholder value is set, in which case a warning is printed and
  #      verification is skipped — intended only for development).
  #   3. Run the installer with --yes --no-daemon (single-user install).
  #   4. Source the Nix profile script so the `nix` command is immediately
  #      available in the current session without reopening a shell.
  #   5. Verify that `nix` is now in PATH using require_command.
  #
  # Requires: curl, sha256sum or shasum or openssl (for checksum verification)
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  require_command curl

  installer_path="$(mktemp)"
  curl -fsSL "$NIX_INSTALLER_URL" -o "$installer_path"

  if [ "$NIX_INSTALLER_SHA256" = "REPLACE_WITH_NIX_INSTALLER_SHA256" ]; then
    printf '%s\n' "warning: NUCLEUS_NIX_INSTALLER_SHA256 is not set; skipping installer checksum verification."
  else
    actual_sha256="$(sha256_of_file "$installer_path")"
    if [ "$actual_sha256" != "$NIX_INSTALLER_SHA256" ]; then
      printf '%s\n' "error: Nix installer checksum mismatch." >&2
      printf '%s\n' "expected: $NIX_INSTALLER_SHA256" >&2
      printf '%s\n' "actual:   $actual_sha256" >&2
      exit 1
    fi
  fi

  sh "$installer_path" --yes --no-daemon
  rm -f "$installer_path"

  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    # shellcheck disable=SC1091
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  fi

  require_command nix
}

ensure_macos_nix_mount() {
  # Ensures the /nix synthetic mount point exists on macOS before any Nix
  # installation is attempted.
  #
  # macOS does not allow creating top-level directories on the root filesystem
  # (APFS volume seal).  Nix requires /nix, so it must be declared in
  # /etc/synthetic.conf and materialised by the apfs.util launch daemon during
  # boot.
  #
  # Behaviour:
  #   - No-op on non-macOS platforms.
  #   - No-op if /nix already exists (e.g. after reboot or prior install).
  #   - Appends 'nix' to /etc/synthetic.conf via sudo if not already present.
  #   - Prints a reboot reminder and exits 1; the user must reboot and then
  #     re-run bootstrap.sh to complete installation.
  if [ "$(uname -s)" != "Darwin" ]; then
    return
  fi

  if [ -e /nix ]; then
    return
  fi

  printf '%s\n' "macOS requires /nix before Nix installation can proceed."

  if [ ! -f /etc/synthetic.conf ] || ! grep -Eq '^nix$' /etc/synthetic.conf; then
    if command -v sudo >/dev/null 2>&1; then
      printf '%s\n' "Adding 'nix' to /etc/synthetic.conf (sudo may prompt)."
      printf 'nix\n' | sudo tee -a /etc/synthetic.conf >/dev/null
    else
      printf '%s\n' "error: sudo is required to write /etc/synthetic.conf on macOS" >&2
      exit 1
    fi
  fi

  printf '%s\n' "Reboot once to materialize /nix, then re-run bootstrap.sh."
  exit 1
}

require_command() {
  # Asserts that a command is available in PATH.
  # Prints an error to stderr and exits 1 if the command is missing.
  # Args: $1 — name of the command to check
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}

sha256_of_file() {
  # Computes the SHA-256 hex digest of a file and prints it to stdout.
  # Tries sha256sum (Linux coreutils), then shasum -a 256 (macOS BSD tools),
  # then openssl dgst -sha256 as a last resort.
  # Calls require_command to abort with a clear error if none are available.
  # Args: $1 — path to the file to hash
  file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{ print $1 }'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{ print $1 }'
    return
  fi

  require_command openssl
  openssl dgst -sha256 "$file_path" | awk '{ print $2 }'
}

load_bootstrap_versions
ensure_macos_nix_mount
bootstrap_nix_if_missing

if ! run_nix profile list 2>/dev/null | grep -q "bootstrap-deps"; then
  printf '%s\n' "Installing bootstrap-managed dependencies..."
  run_nix profile add "$REPO_ROOT/src#bootstrap-deps"
else
  printf '%s\n' "Bootstrap dependencies already present, skipping installation."
fi

if [ "$COMMAND" = "apply" ]; then
  printf '%s\n' "Running apply flow via src#apply..."
  # Health-check is already invoked by apply.sh for each OS branch; calling it
  # here too would print "health checks passed" twice and slow bootstrap down.
  if [ "$skip_ai_sync" = true ]; then
    run_nix run "$REPO_ROOT/src#apply" -- --skip-ai-sync
  else
    run_nix run "$REPO_ROOT/src#apply"
  fi
  exit 0
fi

printf '%s\n' "Bootstrap complete. Run 'nix run ./src#apply' to configure this host."
