#!/usr/bin/env bash
# Installs Nix and the Nix-managed bootstrap dependencies, then optionally
# runs the apply flow.

set -euo pipefail

# Refuse to run as root: privilege escalation is managed internally with sudo
# rather than relying on an already-elevated caller.
if [ "$(id -u)" -eq 0 ] && [ "${force_admin:-false}" = false ]; then
  error "this script must not be run as root. Run as a regular user (sudo is used internally when needed)."
fi

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
REPO_ROOT="$(derive_repo_root)"
VERSIONS_FILE="$SCRIPT_DIR/bootstrap-versions.env"
apply="${NUCLEUS_APPLY:-false}"
force_admin=false

ai_sync="${NUCLEUS_AI_SYNC:-true}"
replica_sync="${NUCLEUS_REPLICA_SYNC:-false}"
target_user="${NUCLEUS_TARGET_USER:-}"
_apply_args=""

usage() {
  usage_std "bootstrap.sh" "[--apply|--no-apply] [--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--force-admin] [--target-user=<name>] [-- <apply-args>...]" "Installs Nix (if absent) and the Nix-managed bootstrap dependencies. By default installs dependencies only. Pass --apply to also run the apply flow."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
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
  --force-admin)
    force_admin=true
    ;;
  --target-user)
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
      error "--target-user requires a non-empty value"
      exit 1
    fi
    target_user="$2"
    shift
    ;;
  --target-user=*)
    target_user="${1#--target-user=}"
    if [ -z "$target_user" ]; then
      error "--target-user requires a non-empty value"
      exit 1
    fi
    ;;
  --)
    shift
    _apply_args="$*"
    break
    ;;
  *)
    error "unsupported argument '$1'"
    usage >&2
    exit 1
    ;;
  esac
  shift
done

run_nix() {
  # warn-dirty off so bootstrap and apply logs surface real failures instead of
  # repeated VCS status noise. NIX_PATH is explicit because darwin-rebuild's
  # `export NIX_PATH=${NIX_PATH:-}` would clear it and override the nix-path
  # config option. --quiet drops store path listings outside verbose mode.
  _nix_quiet_flags=()
  if [ "${NUCLEUS_VERBOSE:-false}" = "false" ]; then
    _nix_quiet_flags=(--quiet)
  fi
  NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" \
    nix "${_nix_quiet_flags[@]}" --option warn-dirty false "$@"
}

load_bootstrap_versions() {
  # `set -a` auto-exports every variable, so the pins reach the installer child.
  # Both NUCLEUS_NIX_INSTALLER_SHA256 and NUCLEUS_NIX_INSTALLER_URL are
  # mandatory and a missing one is a hard error.
  if [ ! -f "$VERSIONS_FILE" ]; then
    error "expected bootstrap versions file at $VERSIONS_FILE"
  fi

  set -a
  # shellcheck source=./bootstrap-versions.env
  . "$VERSIONS_FILE"
  set +a

  if [ -z "${NUCLEUS_NIX_INSTALLER_SHA256:-}" ]; then
    error "NUCLEUS_NIX_INSTALLER_SHA256 missing in $VERSIONS_FILE"
  fi

  if [ -z "${NUCLEUS_NIX_INSTALLER_URL:-}" ]; then
    error "NUCLEUS_NIX_INSTALLER_URL missing in $VERSIONS_FILE"
  fi

  NIX_INSTALLER_SHA256="$NUCLEUS_NIX_INSTALLER_SHA256"
  NIX_INSTALLER_URL="$NUCLEUS_NIX_INSTALLER_URL"
}

bootstrap_nix_if_missing() {
  # Runs the official installer when nix is absent. The pinned digest is
  # verified unless the placeholder value is set, which is a development-only
  # case. Requires curl.
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  require_command curl

  installer_path="$(mktemp)"
  curl -fsSL "$NIX_INSTALLER_URL" -o "$installer_path"

  if [ "$NIX_INSTALLER_SHA256" = "REPLACE_WITH_NIX_INSTALLER_SHA256" ]; then
    warn "NUCLEUS_NIX_INSTALLER_SHA256 is not set; skipping installer checksum verification."
  else
    actual_sha256="$(sha256_of_file "$installer_path")"
    if [ "$actual_sha256" != "$NIX_INSTALLER_SHA256" ]; then
      error "Nix installer checksum mismatch (expected: $NIX_INSTALLER_SHA256, actual: $actual_sha256)"
    fi
  fi

  sh "$installer_path" --yes --no-daemon
  rm -f "$installer_path"

  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    # Not available in the Nix build sandbox, only at runtime after the install.
    # shellcheck disable=SC1091 # reason: file doesn't exist at shellcheck analysis time (created by Nix installer at bootstrap runtime)
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  fi

  require_command nix
}

allow_repo_direnv_if_available() {
  # Auto-allow the canonical repo .envrc so the first `cd` loads the devShell.
  # Only the nucleus checkout is allowed, and every failure is non-fatal: direnv
  # may be absent and .envrc may be missing in partial checkouts.
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
    warn "failed to run 'direnv allow' for $REPO_ROOT"
  fi
}

ensure_macos_nix_mount() {
  # macOS seals the root volume, so a top-level /nix cannot be created. It has
  # to be declared in /etc/synthetic.conf and materialised by apfs.util at boot,
  # which means a reboot before the install can continue.
  if [ "$(uname -s)" != "Darwin" ]; then
    return
  fi

  if [ -e /nix ]; then
    return
  fi

  say "macOS requires /nix before Nix installation can proceed."

  if [ ! -f /etc/synthetic.conf ] || ! grep -Eq '^nix$' /etc/synthetic.conf; then
    if command -v sudo >/dev/null 2>&1; then
      say "Adding 'nix' to /etc/synthetic.conf (sudo may prompt)."
      printf 'nix\n' | sudo tee -a /etc/synthetic.conf >/dev/null
    else
      error "sudo is required to write /etc/synthetic.conf on macOS"
    fi
  fi

  error "Reboot once to materialize /nix, then re-run bootstrap.sh. See src/hosts/MacBook/MANUAL.md."
}

load_bootstrap_versions
ensure_macos_nix_mount
bootstrap_nix_if_missing

if ! run_nix profile list 2>/dev/null | grep -q "bootstrap-deps"; then
  say "Installing bootstrap-managed dependencies..."
  run_nix profile add "$REPO_ROOT/src#bootstrap-deps"
else
  say "Bootstrap dependencies already present, skipping installation."
fi

# PowerShell module provisioning, mirror of Invoke-PowerShellModuleSetup.ps1.
# Reads the lockfile.json psgallery section and installs each module at its
# pinned version. A pin is either a version string or a {version, hash} object;
# only the version is passed on, since Install-Module cannot verify a nupkg
# hash. Shares install-pwsh-module.sh with Nix activation.
provision_pwsh_modules() {
  local _pwsh="$1"
  [ -x "$_pwsh" ] || return 0

  local _lockfile="$REPO_ROOT/src/lockfiles/lockfile.json"
  [ -f "$_lockfile" ] || return 0

  # WHY the privilege command is resolved here and handed over as an argument:
  #   bootstrap.sh never re-executes itself as root, so the pwsh child would run
  #   unprivileged and PowerShellGet would refuse to remove a root-owned copy of
  #   a pinned module. The helper splits that removal into an elevated child of
  #   its own and keeps the install unprivileged, so all this call site has to do
  #   is name the command to escalate through.
  local _sudo
  # WHY no warning when sudo is absent: a host with no copy to remove converges
  #   without it, so a warning here would fire on every run of a host that has
  #   nothing to converge. The helper raises the failure by name, naming the copy
  #   and its owner, at the point where a removal is actually required.
  # check-suppress:suppression_doc: an absent sudo is passed on rather than raised here, because the helper decides whether a removal is needed
  if command -v sudo >/dev/null 2>&1; then
    _sudo="$(command -v sudo)"
  else
    _sudo=''
  fi

  local _modules
  _modules=$("$_pwsh" -NoProfile -Command "
    \$lf = Get-Content -Raw '$(cygpath -w "$_lockfile" 2>/dev/null || echo "$_lockfile")' | ConvertFrom-Json
    if (\$lf.psgallery) { \$lf.psgallery.PSObject.Properties | ForEach-Object { \$v = \$_.Value; if (\$v -isnot [string]) { \$v = \$v.version }; Write-Output \"\$(\$_.Name)|\$v\" } }
  ") || return 0

  while IFS='|' read -r _name _version; do
    [ -n "$_name" ] || continue
    "$SCRIPT_DIR/../src/scripts/packages/install-pwsh-module.sh" \
      "$_pwsh" "$_name" "$_version" "$_sudo"
  done <<<"$_modules"
}

# Try Nix-packaged pwsh first (from runtimeInputs), fall back to system pwsh.
_nix_pwsh=$(command -v pwsh 2>/dev/null || true) # check-suppress:suppression_doc: fallback to empty when pwsh is absent
if [ -n "$_nix_pwsh" ]; then
  provision_pwsh_modules "$_nix_pwsh"
fi

allow_repo_direnv_if_available

if [ "$apply" = true ]; then
  say "Running apply flow via src#apply..."
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
    # shellcheck disable=SC2086 # reason: word splitting is intentional for passthrough
    set -- "$@" $_apply_args
  fi

  run_nix run "$REPO_ROOT/src#apply" -- "$@"
  exit 0
fi

say "Bootstrap complete. Run 'nix run ./src#apply' to configure this host."
