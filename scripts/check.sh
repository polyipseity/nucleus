#!/usr/bin/env bash
# Fast pre-commit checks. PSSA and Nix tests run in the test pipeline.
set -euo pipefail

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

_ORCH_SCRIPT_DIR="$SCRIPT_DIR"
_NUCLEUS_CHECKS_DIR="$(CDPATH='' cd -- "$_ORCH_SCRIPT_DIR/../src/scripts/checks" && pwd)"
# shellcheck source=../src/scripts/checks/check-lib.sh
. "$_NUCLEUS_CHECKS_DIR/check-lib.sh"
# shellcheck source=../src/scripts/checks/check-steps.sh
. "$_NUCLEUS_CHECKS_DIR/check-steps.sh"

# Disable Nix auto-GC for the whole scripted pipeline. The Data volume is often
# >90% full, so Nix's default min-free (40GiB) triggers auto-GC that deletes
# flake-input source trees a parallel step still needs mid-eval (see
# src/scripts/lib/lib.sh merge_nix_config).
usage() {
  usage_std "check.sh" "[packer|pwsh|sh] [--fail-fast|--no-fail-fast] [--scoped|--full] [--online] [--verbose[=<ids>]] [--no-verbose] [--only-steps=<ids>] [path ...]" "Run repository validation checks. With a subcommand, run only that check; without one, run all checks with parallel step dispatch (capped at PARALLEL_JOBS). Subcommands: packer (Packer template validation), pwsh (PowerShell syntax + naming lint), sh (shell script lint). Default: scoped if paths given, full otherwise."
}

# packer subcommand, inline body of scripts/check-packer.sh

do_packer() {
  REPO_ROOT=$(derive_repo_root)
  cd "$REPO_ROOT"

  usage() {
    usage_std "check.sh packer" "[--validate-only] [path ...]" "Validate Packer template formatting and configuration. With no arguments, checks all .pkr.hcl files under src/vms/. With arguments, checks only the provided paths. --validate-only skips the packer fmt -check phase."
  }

  _validate_only=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --validate-only)
      _validate_only=true
      shift
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
    esac
  done

  require_command jq

  # Packer plugins need Unix sockets for IPC and the sandbox blocks socket
  # creation (allowAllUnixSockets: false).
  # ref: src/users/default/srt/settings.json
  if [ "${SANDBOX_RUNTIME:-0}" = "1" ]; then
    notice "Packer validation skipped (SRT sandbox blocks Unix sockets)"
    return 0
  fi

  require_command packer

  # Recommended pattern, sharing the plugin cache across invocations:
  # https://developer.hashicorp.com/packer/docs/plugins#plugin-cache
  export PACKER_PLUGIN_CACHE_DIR="${PACKER_PLUGIN_CACHE_DIR:-$HOME/.cache/packer/plugins}"

  # The lockfile uses nixpkgs arch names (x86_64-linux, aarch64-linux), uname does not.
  _arch="$(uname -m)"
  case "$_arch" in
  x86_64) _nix_arch="x86_64-linux" ;;
  arm64 | aarch64) _nix_arch="aarch64-linux" ;;
  *)
    error "unsupported architecture '$_arch' for NixOS ISO checksum lookup"
    exit 1
    ;;
  esac

  _nixos_digest="$(jq -r --arg arch "$_nix_arch" '(."vm-setup"."nixos-iso" // {})[$arch].digest // "none"' "$REPO_ROOT/src/lockfiles/lockfile.json")"

  # Formatting is skipped with --validate-only; step 01 covers packer fmt.
  if ! $_validate_only; then
    if [ "$#" -gt 0 ]; then
      packer fmt -check "$@"
    else
      packer fmt -check -recursive src/vms/
    fi
  fi

  # Validate each Packer template in its own directory (needed for plugin
  # resolution and relative path references).
  # Each template may require different -var flags for required variables.
  #
  # Filter the known checksum-none warning (Windows template only). Microsoft
  # publishes no stable Windows 11 ISO checksums, so
  # src/vms/Windows/packer.pkr.hcl sets iso_checksum to "none" on purpose. The
  # packer validate exit code below is still enforced; only the expected
  # warning text is hidden. check_packer_validate_annotations authorizes the
  # filter: the annotation must exist before the warning may be hidden.
  _filter_known_packer_warnings() {
    awk '
      /Warning: A checksum of .none. was specified/ { skip=1 }
      skip && /\(source code not available\)/ { skip=0; next }
      !skip { print }
    '
  }

  # packer_validate annotation gate: iso_checksum resolving to "none" must carry
  # `# check-suppress:packer_validate:` on that line. scripts/check-packer.ps1
  # consumes the same annotation.
  check_packer_validate_annotations() {
    local tpl="$REPO_ROOT/src/vms/Windows/packer.pkr.hcl"
    [ -f "$tpl" ] || return 0
    local content line effective varname violations=0
    content=$(<"$tpl")
    while IFS= read -r line; do
      case "$line" in
      *iso_checksum[[:space:]]*=*)
        effective=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*iso_checksum[[:space:]]*=//; s/#.*//; s/[[:space:]]//g')
        if [[ "$effective" =~ ^var\.([A-Za-z0-9_]+)$ ]]; then
          varname="${BASH_REMATCH[1]}"
          effective=$(printf '%s\n' "$content" | awk -v v="$varname" '
              $0 ~ ("variable \"" v "\"") { block=1; next }
              block && /^[[:space:]]*default[[:space:]]*=/ {
                sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/, "")
                gsub(/[[:space:]]/, "")
                print
                exit
              }
              block && /^\}/ { exit }
            ')
        fi
        case "$effective" in
        none | '"none"' | "'none'")
          if [[ "$line" != *'# check-suppress:packer_validate:'* ]]; then
            error "iso_checksum resolves to 'none' without '# check-suppress:packer_validate:' annotation: $line"
            violations=1
          fi
          ;;
        esac
        ;;
      esac
    done <<<"$content"
    return "$violations"
  }

  check_packer_validate_annotations || {
    error "packer_validate annotation check failed"
    exit 1
  }

  validate_dir() {
    local dir="$1"
    say "validating $dir..."
    local vars=()
    case "$dir" in
    *NixOS)
      vars=(-var guest_username=dummy -var guest_password=dummy -var guest_hostname=dummy -var nixos_iso_url=https://dummy.iso -var "nixos_iso_checksum=$_nixos_digest")
      ;;
    *Windows)
      vars=(-var windows_iso=dummy.iso -var hostfwd=dummy -var guest_hostname=dummy)
      ;;
    *macOS)
      vars=(-var macos_version=14.0 -var vm_id=dummy -var cpus=2 -var memory_gib=4 -var disk_size_gib=40 -var guest_username=dummy -var guest_password=dummy -var ssh_username=dummy -var ssh_password=dummy -var tart_image_ref=dummy -var vm_hostname=dummy)
      ;;
    esac
    # 2>&1 into the filter: the warning goes to stderr, and pipefail keeps
    # the packer validate exit code authoritative.
    (cd "$dir" && packer init . && packer validate "${vars[@]}" . 2>&1 | _filter_known_packer_warnings)
  }

  # Preflight: install plugins sequentially. NixOS and Windows share the qemu
  # plugin, and a parallel download races on the cached binary ("text file busy").
  (cd src/vms/NixOS && packer init .) || true   # check-suppress:suppression_doc: plugin download may already be cached; init failure is non-fatal
  (cd src/vms/Windows && packer init .) || true # check-suppress:suppression_doc: plugin download may already be cached; init failure is non-fatal
  if [ "$(uname)" = "Darwin" ]; then
    (cd src/vms/macOS && packer init .) || true # check-suppress:suppression_doc: plugin download may already be cached; init failure is non-fatal
  fi

  # Each VM directory validates independently; temp exit files aggregate race-free.
  _pkr_tmpdir=$(mktemp -d) || {
    error "failed to create temp directory for packer validation"
    exit 1
  }

  {
    _vd_exit=0
    validate_dir src/vms/NixOS || _vd_exit=$?
    echo "$_vd_exit" >"$_pkr_tmpdir/exit-nixos"
  } &
  {
    _vd_exit=0
    validate_dir src/vms/Windows || _vd_exit=$?
    echo "$_vd_exit" >"$_pkr_tmpdir/exit-windows"
  } &

  # The macOS template needs the Tart plugin, which is macOS-only.
  if [ "$(uname)" = "Darwin" ]; then
    {
      _vd_exit=0
      validate_dir src/vms/macOS || _vd_exit=$?
      echo "$_vd_exit" >"$_pkr_tmpdir/exit-macos"
    } &
  else
    say "skipping macOS Packer template validation (requires Tart plugin on macOS)"
  fi

  wait

  _pkr_exit=0
  for _pkr_ef in "$_pkr_tmpdir"/exit-*; do
    [ -f "$_pkr_ef" ] || continue
    read -r _pkr_code <"$_pkr_ef"
    [ "$_pkr_code" != "0" ] && _pkr_exit=$((_pkr_exit + 1))
  done

  rm -rf -- "$_pkr_tmpdir"

  if [ "$_pkr_exit" -gt 0 ]; then
    error "Packer validation failed with $_pkr_exit error(s)"
    exit 1
  fi
}

# sh subcommand, ShellCheck lint (shellcheck -x -S style)

do_sh() {
  REPO_ROOT=$(derive_repo_root)
  cd "$REPO_ROOT"

  usage() {
    usage_std "check.sh sh" "[--scoped] [path ...]" "Validate shell script syntax and lint quality with treefmt (ShellCheck). With no arguments, checks all tracked *.sh files from Git. With arguments, checks only the provided paths. Use --scoped to skip whole-repo discovery when no paths are given."
  }

  # --source-path=SCRIPTDIR resolves `# shellcheck source=` against each script's
  # own directory (e.g. bootstrap-versions.env next to bootstrap.sh), and -x
  # follows external sources. Flags live in src/treefmt.nix; scripts/check.ps1
  # (Invoke-CheckSh) passes --source-path per file.
  _SCOPED=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --scoped)
      _SCOPED=true
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
    esac
    shift
  done

  if [ "$#" -gt 0 ]; then
    # Paths given: treefmt runs on them regardless of --scoped.
    treefmt --fail-on-change "$@"
    count="$#"
  elif $_SCOPED; then
    say 'no shell scripts to check (scoped mode).'
    exit 0
  else
    files="$(git ls-files '*.sh' ':(exclude)vendor/')" || true # check-suppress:suppression_doc: git ls-files returns 1 when no matches found
    if [ -z "$files" ]; then
      say 'no shell scripts to check.'
      exit 0
    fi
    # shellcheck disable=SC2086 # reason: word splitting intentional for treefmt file args
    treefmt --fail-on-change $files
    count=$(printf '%s\n' "$files" | awk 'NF { c += 1 } END { print c + 0 }')
  fi

  say "shell script check passed for $count files."
}

# pwsh subcommand, PowerShell syntax (check-pwsh.ps1)

do_pwsh() {
  local _exit=0
  pwsh -NoProfile -File "$_ORCH_SCRIPT_DIR/../src/scripts/checks/check-pwsh.ps1" "$@" || _exit=$?
  return $_exit
}

# Main dispatch

# WHY: the subcommand word is captured first, then dropped (tolerating its
# absence) so every do_* handler receives only its own remaining options.
action="${1:-}"
case "$action" in
-h | --help | help)
  usage
  exit 0
  ;;
packer | pwsh | sh)
  shift
  ;;
*)
  action=""
  ;;
esac

if [ -n "$action" ]; then
  case "$action" in
  packer) do_packer "$@" ;;
  sh) do_sh "$@" ;;
  pwsh) do_pwsh "$@" ;;
  esac
  exit $?
fi

NIX_CONFIG="$(merge_nix_config)"
export NIX_CONFIG

cd "$REPO_ROOT" || exit
parse_args "$@"
preflight_check
run_all_steps
aggregate_results
