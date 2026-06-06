#!/usr/bin/env bash
# bootstrap.sh — Install Nix (if absent) and run the Nix-managed bootstrap/apply flow.
#
# Installs Nix if not already present, then optionally runs the apply flow to
# converge the full system configuration. By default installs dependencies only.
# Pass --apply to also run the apply flow.
#
# Arguments:
#   --apply|--no-apply             Run the apply flow after installing dependencies (default: --no-apply).
#   --ai-sync|--no-ai-sync         Control post-apply Ollama model sync (default: --ai-sync).
#   --replica-sync|--no-replica-sync  Control immediate post-apply replica sync (default: --no-replica-sync).
#   --target-user <name>           Select the Home Manager flake profile on standalone Linux hosts.
#
# Environment variables:
#   NUCLEUS_APPLY        Override the --apply default (default: false).
#   NUCLEUS_AI_SYNC      Override the --ai-sync default (default: true).
#   NUCLEUS_REPLICA_SYNC Override the --replica-sync default (default: false).
#   NUCLEUS_TARGET_USER  Override the --target-user default (default: unset).
#
# Exit conditions:
#   0 on success; non-zero if any step fails.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/../src/scripts/lib.sh"
REPO_ROOT="$(resolve_nucleus_root)"
VERSIONS_FILE="$SCRIPT_DIR/bootstrap-versions.env"
apply="${NUCLEUS_APPLY:-false}"

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
ai_sync="${NUCLEUS_AI_SYNC:-true}"
replica_sync="${NUCLEUS_REPLICA_SYNC:-false}"
target_user="${NUCLEUS_TARGET_USER:-}"
_apply_args=""

usage() {
  usage_std "bootstrap.sh" "[--apply|--no-apply] [--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--target-user=<name>] [-- <apply-args>...]" "Installs Nix (if absent) and the Nix-managed bootstrap dependencies. By default installs dependencies only. Pass --apply to also run the apply flow."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --apply)
      apply=true
      ;;
    --no-apply)
      apply=false
      ;;
    --ai-sync)
      ai_sync=true
      ;;
    --no-ai-sync)
      ai_sync=false
      ;;
    --replica-sync)
      replica_sync=true
      ;;
    --no-replica-sync)
      replica_sync=false
      ;;
    --target-user)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf '%s\n' "error: --target-user requires a non-empty value" >&2
        exit 1
      fi
      target_user="$2"
      shift
      ;;
    --target-user=*)
      target_user="${1#--target-user=}"
      if [ -z "$target_user" ]; then
        printf '%s\n' "error: --target-user requires a non-empty value" >&2
        exit 1
      fi
      ;;
    --)
      shift
      _apply_args="$*"
      break
      ;;
    *)
      printf '%s\n' "error: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

run_nix() {
  # Execute nix with the merged config for this script invocation.
  # Suppress the repeated dirty-tree warning so bootstrap/apply logs surface
  # actionable failures instead of identical VCS status noise.
  NIX_CONFIG="$(merge_nix_config)" nix --option warn-dirty false "$@"
}

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
  # shellcheck source=./bootstrap-versions.env
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

allow_repo_direnv_if_available() {
  # Auto-allow this repository's .envrc when direnv is installed.
  # This keeps first-run developer UX smooth: entering the repo immediately
  # loads the nix-direnv-managed devShell without an extra manual allow step.
  #
  # Scope guard: only allow the canonical nucleus repository root. This avoids
  # implicitly trusting arbitrary checkouts that happen to include this script.
  #
  # Non-fatal behavior is intentional:
  # - direnv might not be installed yet on fresh machines.
  # - .envrc may be absent in forks/partial checkouts.
  # - failing hard here would block bootstrap/apply for a convenience feature.
  if ! command -v direnv >/dev/null 2>&1; then
    return
  fi

  if [ ! -f "$REPO_ROOT/.envrc" ]; then
    return
  fi

  if [ "$(basename -- "$REPO_ROOT")" != "nucleus" ]; then
    return
  fi

  if ! direnv allow "$REPO_ROOT"; then
    printf '%s\n' "warning: failed to run 'direnv allow' for $REPO_ROOT" >&2
  fi
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

load_bootstrap_versions
ensure_macos_nix_mount
bootstrap_nix_if_missing

if ! run_nix profile list 2>/dev/null | grep -q "bootstrap-deps"; then
  printf '%s\n' "Installing bootstrap-managed dependencies..."
  run_nix profile add "$REPO_ROOT/src#bootstrap-deps"
else
  printf '%s\n' "Bootstrap dependencies already present, skipping installation."
fi

allow_repo_direnv_if_available

if [ "$apply" = true ]; then
  printf '%s\n' "Running apply flow via src#apply..."
  # Health-check is already invoked by apply.sh for each OS branch; calling it
  # here too would print "health checks passed" twice and slow bootstrap down.
  set --
  if [ "$ai_sync" = false ]; then
    set -- "$@" --no-ai-sync
  fi
  if [ "$replica_sync" = true ]; then
    set -- "$@" --replica-sync
  fi
  if [ -n "$target_user" ]; then
    set -- "$@" --target-user "$target_user"
  fi
  if [ -n "$_apply_args" ]; then
    # shellcheck disable=SC2086  # word splitting is intentional for passthrough
    set -- "$@" $_apply_args
  fi

  run_nix run "$REPO_ROOT/src#apply" -- "$@"
  exit 0
fi

printf '%s\n' "Bootstrap complete. Run 'nix run ./src#apply' to configure this host."
