#!/usr/bin/env bash
# Runs Nix test suite, ShellCheck, and PSScriptAnalyzer.
#
# File discovery policy:
# Test file discovery is dynamic — the script finds all *.nix files under
# tests/ automatically. Adding a new test directory does NOT require
# editing this script.
set -uo pipefail
exit_code=0
FAIL_FAST=true

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

REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

usage() {
  usage_std "test.sh" "[-q|--quiet] [--fail-fast|--no-fail-fast] [--skip-system-build]" "Run the repository test suite. With --quiet, only show FAIL lines and nix output for failing tests. By default, all output is shown. --fail-fast exits immediately on first failure (default); --no-fail-fast accumulates all failures. --skip-system-build skips building the system configuration."
}

# Flags
quiet_mode=false
skip_system_build=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|--quiet) quiet_mode=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --no-fail-fast) FAIL_FAST=false; shift ;;
    --fail-fast) FAIL_FAST=true; shift ;;
    --skip-system-build) skip_system_build=true; shift ;;
    --) shift; break ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *) break ;;
  esac
done

# No positional arguments accepted.
if [ "$#" -gt 0 ]; then
  error "unexpected argument '$1'"
  usage >&2
  exit 1
fi

_step=0

# 1. Nix test suite — auto-discover and run all *.nix test files
section "$((_step += 1))" "Nix test suite"
tmp_failed=$(mktemp) || { error "failed to create temp file"; }
if [ "$quiet_mode" = true ]; then
  # Quiet: suppress Testing: / PASS: lines and nix output on success.
  # shellcheck disable=SC2016 # reason: $f/$2/$tmp are literal in sh -c string, not expanded here
  find tests -name '*.nix' -type f ! -name 'lib.nix' | sort \
    | xargs -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" -I{} sh -c '
        f="$1"; tmp="$2"
        if out=$(nix-instantiate --eval --strict "$f" 2>&1); then
          true
        else
          echo "FAIL: $f" >&2
          echo "$f" >> "$tmp"
          echo "$out" >&2
        fi
      ' _ {} "$tmp_failed"
else
  # Normal: show Testing: / PASS: lines and nix output for all tests.
  # shellcheck disable=SC2016 # reason: $f/$2 are literal in sh -c string, not expanded here
  find tests -name '*.nix' -type f ! -name 'lib.nix' | sort \
    | xargs -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" -I{} sh -c 'f="$1"; echo "Testing: $f" >&2; if ! nix-instantiate --eval --strict "$f"; then echo "FAIL: $f" >&2; echo "$f" >> "$2"; else echo "PASS: $f" >&2; fi' _ {} "$tmp_failed"
fi
if [ -s "$tmp_failed" ]; then
  error "FAILED Nix tests:"
  cat "$tmp_failed" >&2
  rm -f "$tmp_failed"
  exit_code=1
fi
rm -f "$tmp_failed"
say "all Nix tests passed."
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# 2. Shell script linting (ShellCheck)
section "$((_step += 1))" "Shell script linting"
bash scripts/check-sh.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# 3. PowerShell lint (PSScriptAnalyzer)
section "$((_step += 1))" "PowerShell lint"
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# 4. Nucleus apps smoke tests (build + --help / dry-run)
section "$((_step += 1))" "Nucleus apps smoke tests"
bash tests/scripts/nucleus-apps-smoke-tests.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# 5. System config build — build all derivations in the host system config.
# WHY soft-fail: building derivations is slow and network-dependent. Always
# accumulates exit code regardless of FAIL_FAST. Use --skip-system-build to
# skip this step entirely.
if [ "$skip_system_build" != true ]; then
  section "$((_step += 1))" "System config build"
  case "$(uname)" in
    Darwin) attr="darwinConfigurations.macbook.system" ;;
    Linux)
      if [ -d /etc/nixos ]; then
        attr="nixosConfigurations.nixos.config.system.build.toplevel"
      else
        attr="homeConfigurations.polyipseity.activationPackage"
      fi
      ;;
    *)
      say "system config build: unsupported OS ($(uname)), skipping."
      skip_system_build=true
      ;;
  esac
  if [ "$skip_system_build" != true ]; then
    nix build --no-link --keep-going --print-out-paths "./src#$attr" || exit_code=$?
  fi
fi

nuc_done
exit $exit_code
