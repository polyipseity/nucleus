#!/usr/bin/env bash
# Behavioral tests for the lockfile version enforcement check step
# (src/scripts/checks/check-steps/16-lockfile-enforcement.sh).
#
# Each test builds a fake repo root (src/lockfiles/lockfile.json) plus a
# $tmp/bin of stub tools that emit a controlled "installed" record, then
# runs run_lockfile_enforcement with HOME/PATH pointed at the fake root so
# the step's probes resolve the stub tools (which shadow the real ones on
# PATH) and the fake bun global record.  We assert that drift produces a
# non-zero exit and that matching versions pass, and that suggestions
# always warn (never error).
#
# Run with: bash tests/scripts/lockfile-enforcement-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

STEP_DIR="$REPO_ROOT/src/scripts/checks/check-steps"
CHECK_LIB="$REPO_ROOT/src/scripts/checks/check-lib.sh"

# Source the step under test exactly once.
NUCLEUS_REPO_ROOT="$REPO_ROOT" . "$CHECK_LIB"
NUCLEUS_REPO_ROOT="$REPO_ROOT" . "$STEP_DIR/16-lockfile-enforcement.sh"

# Build a fake repo root with a lockfile.  Prints the repo root path.
# $1 = extra JSON to merge into the lockfile root (optional).
setup_fake_repo() {
  local extra="${1:-}"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src/lockfiles" "$dir/bin" "$dir/.bun/install/global"
  cat >"$dir/src/lockfiles/lockfile.json" <<EOF
{
  "\$schema": "./lockfile.schema.json",
  "bun": { "clawhub": "0.20.0" },
  "uv": { "yamllint": "1.35.1" },
  "rustup": { "stable": "2026-04-14" },
  "cargo-binstall": { "pay-respects": "0.8.8" },
  "pwsh": { "Pester": "6.1.0" },
  "suggestions": { "homebrew": {}, "vscode": {} }$extra
}
EOF
  printf '%s\n' "$dir"
}

# Stub bun: the enforcement step reads ~/.bun/install/global/package.json
# directly (it does not execute bun), so write that file with the given
# installed versions.  It also requires `bun` itself to be on PATH to
# consider the section applicable, so create a dummy bun executable too.
# $1 = repo root, $2 = JSON object body for dependencies.
stub_bun() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.bun/install/global" "$dir/bin"
  cat >"$dir/.bun/install/global/package.json" <<EOF
{ "dependencies": { $body } }
EOF
  cat >"$dir/bin/bun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/bin/bun"
}

# Stub uv: emits a tool list with the given lines.
stub_uv() {
  local dir="$1"; shift
  cat >"$dir/bin/uv" <<EOF
#!/usr/bin/env bash
[ "\$1" = "tool" ] && [ -n "\$2" ] && [ "\$2" = "list" ] && cat <<'LIST'
$*
LIST
exit 0
EOF
  chmod +x "$dir/bin/uv"
}

# Stub cargo: emits install --list output with the given lines.
stub_cargo() {
  local dir="$1"; shift
  cat >"$dir/bin/cargo" <<EOF
#!/usr/bin/env bash
[ "\$1" = "install" ] && [ "\$2" = "--list" ] && cat <<'LIST'
$*
LIST
exit 0
EOF
  chmod +x "$dir/bin/cargo"
}

# Stub rustup: emits toolchain list with the given lines.
stub_rustup() {
  local dir="$1"; shift
  cat >"$dir/bin/rustup" <<EOF
#!/usr/bin/env bash
[ "\$1" = "toolchain" ] && [ "\$2" = "list" ] && cat <<'LIST'
$*
LIST
exit 0
EOF
  chmod +x "$dir/bin/rustup"
}

# Stub pwsh: the step invokes
#   pwsh -NoProfile -NonInteractive -Command "Get-Module ... -Name '<mod>' ..."
# The module name is the token after -Name (quoted or bare).  $1 = repo
# root, $2 = case body mapping module name to version.
stub_pwsh() {
  local dir="$1" body="$2"
  cat >"$dir/bin/pwsh" <<EOF
#!/usr/bin/env bash
script="\$4"
mod="\${script#*-Name }"
mod="\${mod#\'}"
mod="\${mod%%\'*}"
case "\$mod" in
$body
esac
exit 0
EOF
  chmod +x "$dir/bin/pwsh"
}

# Minimal PATH: only the stub bin dir plus the real dirs for the tools the
# step/helpers actually need (bash, jq, awk, grep, cat).  jq is resolved to
# its nix store path so we deliberately EXCLUDE /etc/profiles/per-user/*/bin,
# which would otherwise expose the real bun/uv/cargo/rustup/pwsh and make
# unstubbed tools error.  The stub bin dir is prepended, so any stubbed tool
# shadows the real one.
MIN_PATH="$(dirname "$(readlink -f "$(command -v bash)")"):$(dirname "$(readlink -f "$(command -v jq)")"):$(dirname "$(readlink -f "$(command -v awk)")"):$(dirname "$(readlink -f "$(command -v grep)")"):$(dirname "$(readlink -f "$(command -v cat)")")"

# Run the step with the fake root on PATH/HOME.  Prints output; the caller
# inspects $? after this returns.  Use via run_step_capture.
run_step_in() {
  local dir="$1"
  HOME="$dir" PATH="$dir/bin:$MIN_PATH" run_lockfile_enforcement false "$dir" 2>&1
}

# Capture output into RUN_OUT and exit code into RUN_RC.  Must not let a
# non-zero step exit abort this script under set -e, so reset RUN_RC and
# capture via ||.
run_step_capture() {
  local dir="$1"
  RUN_RC=0
  RUN_OUT="$(run_step_in "$dir")" || RUN_RC=$?
}

test_matching_versions_pass() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_bun "$tmp" '"clawhub": "0.20.0"'
  stub_uv "$tmp" 'yamllint v1.35.1'
  stub_cargo "$tmp" 'pay-respects v0.8.8'
  stub_rustup "$tmp" 'stable-2026-04-14-aarch64-apple-darwin (default)'
  stub_pwsh "$tmp" '  "Pester") echo "6.1.0" ;;'
  local out rc
  run_step_capture "$tmp"; rc="$RUN_RC"; out="$RUN_OUT"
  if [ "$rc" -eq 0 ]; then
    assert_pass "matching versions pass enforcement"
  else
    assert_fail "matching versions pass enforcement" "exit $rc; output: $out"
  fi
  rm -rf "$tmp"
}

test_drift_errors() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_bun "$tmp" '"clawhub": "0.15.0"'
  stub_uv "$tmp" 'yamllint v1.35.1'
  stub_cargo "$tmp" 'pay-respects v0.8.8'
  stub_rustup "$tmp" 'stable-2026-04-14-aarch64-apple-darwin (default)'
  stub_pwsh "$tmp" '  "Pester") echo "6.1.0" ;;'
  local out rc
  run_step_capture "$tmp"; rc="$RUN_RC"; out="$RUN_OUT"
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'bun.clawhub: expected 0.20.0, installed 0.15.0'; then
    assert_pass "version drift errors with expected message"
  else
    assert_fail "version drift errors with expected message" "exit $rc; output: $out"
  fi
  rm -rf "$tmp"
}

test_missing_tool_skips_section() {
  local tmp
  tmp="$(setup_fake_repo)"
  # No bun/uv/cargo/rustup/pwsh stubs on PATH -> every section must be
  # skipped (not error).  The step still warns for suggestions.
  local out rc
  run_step_capture "$tmp"; rc="$RUN_RC"; out="$RUN_OUT"
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'bun: not installed; skipping enforcement'; then
    assert_pass "missing tool (bun) skips section without error"
  else
    assert_fail "missing tool (bun) skips section without error" "exit $rc; output: $out"
  fi
  rm -rf "$tmp"
}

test_suggestions_always_warn() {
  local tmp
  tmp="$(setup_fake_repo)"
  local out rc
  run_step_capture "$tmp"; rc="$RUN_RC"; out="$RUN_OUT"
  if printf '%s\n' "$out" | grep -q 'suggestions: warning: homebrew: non-authoritative suggestion'; then
    assert_pass "suggestions always warn (non-authoritative)"
  else
    assert_fail "suggestions always warn (non-authoritative)" "output: $out"
  fi
  rm -rf "$tmp"
}

test_vcs_pin_skipped() {
  local tmp
  tmp="$(setup_fake_repo ', "uv": { "discord-music-rpc": { "rev": "abc123", "source": "https://github.com/example/ext.discord-music-rpc" } }')"
  # Stub yamllint matching so the string pin does not error; the VCS pin
  # (discord-music-rpc) must be skipped, not version-verified.
  stub_uv "$tmp" 'yamllint v1.35.1'
  local out rc
  run_step_capture "$tmp"; rc="$RUN_RC"; out="$RUN_OUT"
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'VCS-pinned (rev)'; then
    assert_pass "VCS-pinned entry is skipped (not version-verifiable)"
  else
    assert_fail "VCS-pinned entry is skipped (not version-verifiable)" "exit $rc; output: $out"
  fi
  rm -rf "$tmp"
}

section "lockfile-enforcement" "Lockfile version enforcement"
test_matching_versions_pass
test_drift_errors
test_missing_tool_skips_section
test_suggestions_always_warn
test_vcs_pin_skipped

if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "FAILED: $TESTS_FAILED test(s)"
  exit 1
fi
echo "All lockfile-enforcement tests passed."
