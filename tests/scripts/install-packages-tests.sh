#!/usr/bin/env bash
# Behavioral tests for the POSIX package install scripts that converge to
# lockfile pins: install-bun-packages.sh, install-uv-tools.sh,
# init-rustup.sh, install-cargo-binstall-packages.sh.
#
# Each test builds a fake repo root (src/lockfiles/lockfile.json) plus a
# $tmp/bin of stub tools that record the install spec they were handed, then
# runs the real script with NUCLEUS_REPO_ROOT pointing at the fake root so
# derive_repo_root resolves the lockfile.  We assert the version-pinned spec
# (pkg@version / pkg==version / channel-date / VCS) is passed to the installer.
#
# Run with: bash tests/scripts/install-packages-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

PKG_DIR="$REPO_ROOT/src/scripts/packages"

# Build a fake repo root with a lockfile and stub tool bin dir.  Prints the
# repo root path.  The lockfile mirrors the real shape for the sections the
# tests exercise (bun / uv / rustup / cargo-binstall), including one VCS pin.
setup_fake_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src/lockfiles" "$dir/bin"
  cat >"$dir/src/lockfiles/lockfile.json" <<'EOF'
{
  "$schema": "./lockfile.schema.json",
  "bun": {
    "clawhub": "0.20.0",
    "@mariozechner/pi-coding-agent": "0.73.1"
  },
  "uv": {
    "yamllint": "1.35.1",
    "paddleocr": "3.6.0",
    "discord-music-rpc": {
      "rev": "bba71027a684db53f3fcde5adbd3d42627241a83",
      "source": "https://github.com/example/ext.discord-music-rpc"
    }
  },
  "rustup": {
    "stable": "2026-04-14"
  },
  "cargo-binstall": {
    "nickel-lang-lsp": "1.17.0",
    "pay-respects": "0.8.8"
  }
}
EOF
  printf '%s\n' "$dir"
}

# Make a stub installer that appends its full argument list (one line per
# invocation) to $CALLS_DIR/calls-$name.txt and exits 0.  $1 = tool name, $2 = repo root.
stub_tool() {
  local name="$1" dir="$2"
  cat >"$dir/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CALLS_DIR/calls-$name.txt"
exit 0
EOF
  chmod +x "$dir/bin/$name"
}

# Run a package script with the fake repo root + stub bin dir on PATH.
run_pkg_script() {
  local script="$1" repo_root="$2"
  shift 2
  CALLS_DIR="$repo_root" NUCLEUS_REPO_ROOT="$repo_root" PATH="$repo_root/bin:$PATH" \
    bash "$PKG_DIR/$script" "$@"
}

test_bun_install_passes_version_pins() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool bun "$tmp"
  # No global package.json -> both desired packages are fresh installs.
  if run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-bun-packages runs to completion"
  else
    assert_fail "install-bun-packages runs to completion" "exit code $?"
  fi
  if grep -qxF 'install -g --ignore-scripts clawhub@0.20.0' "$tmp/calls-bun.txt"; then
    assert_pass "install-bun-packages pins clawhub@0.20.0 from lockfile"
  else
    assert_fail "install-bun-packages pins clawhub@0.20.0 from lockfile" "calls: $(cat "$tmp/calls-bun.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-bun.txt"
  rm -rf "$tmp"
}

test_uv_install_passes_version_pins() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool uv "$tmp"
  # uv tool list emits nothing -> both desired tools are fresh installs.
  if run_pkg_script install-uv-tools.sh "$tmp" \
    "$tmp/bin/uv" "$(command -v awk)" "$(command -v grep)" "$(command -v jq)" \
    '{"paddleocr":"3.11"}' \
    >"$tmp/out.txt" 2>&1; then
    assert_pass "install-uv-tools runs to completion"
  else
    assert_fail "install-uv-tools runs to completion" "exit code $?"
  fi
  if grep -qxF 'tool install --no-build --python 3.11 paddleocr==3.6.0' "$tmp/calls-uv.txt"; then
    assert_pass "install-uv-tools pins paddleocr==3.6.0 from lockfile"
  else
    assert_fail "install-uv-tools pins paddleocr==3.6.0 from lockfile" "calls: $(cat "$tmp/calls-uv.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-uv.txt"
  rm -rf "$tmp"
}

test_rustup_install_passes_channel_date() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool rustup "$tmp"
  # toolchain list emits nothing -> stable toolchain is a fresh install.
  if run_pkg_script init-rustup.sh "$tmp" "$tmp/bin/rustup" "$(command -v jq)" >"$tmp/out.txt" 2>&1; then
    assert_pass "init-rustup runs to completion"
  else
    assert_fail "init-rustup runs to completion" "exit code $?"
  fi
  if grep -qxF 'toolchain install stable-2026-04-14 --no-self-update' "$tmp/calls-rustup.txt"; then
    assert_pass "init-rustup pins stable-2026-04-14 from lockfile"
  else
    assert_fail "init-rustup pins stable-2026-04-14 from lockfile" "calls: $(cat "$tmp/calls-rustup.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-rustup.txt"
  rm -rf "$tmp"
}

test_cargo_binstall_passes_version_pins() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool cargo-binstall "$tmp"
  # cargo install --list emits nothing -> both desired crates are fresh installs.
  if run_pkg_script install-cargo-binstall-packages.sh "$tmp" \
    "$(command -v jq)" "$(command -v awk)" \
    '["nickel-lang-lsp","pay-respects"]' \
    "$tmp/bin/cargo" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-cargo-binstall-packages runs to completion"
  else
    assert_fail "install-cargo-binstall-packages runs to completion" "exit code $?"
  fi
  if grep -qxF -- '--no-confirm nickel-lang-lsp@1.17.0' "$tmp/calls-cargo-binstall.txt"; then
    assert_pass "install-cargo-binstall-packages pins nickel-lang-lsp@1.17.0 from lockfile"
  else
    assert_fail "install-cargo-binstall-packages pins nickel-lang-lsp@1.17.0 from lockfile" "calls: $(cat "$tmp/calls-cargo-binstall.txt" 2>/dev/null)"
  fi
  if grep -qxF -- '--no-confirm pay-respects@0.8.8' "$tmp/calls-cargo-binstall.txt"; then
    assert_pass "install-cargo-binstall-packages pins pay-respects@0.8.8 from lockfile"
  else
    assert_fail "install-cargo-binstall-packages pins pay-respects@0.8.8 from lockfile" "calls: $(cat "$tmp/calls-cargo-binstall.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-cargo-binstall.txt"
  rm -rf "$tmp"
}

section "install-packages" "lockfile pinning"
test_bun_install_passes_version_pins
test_uv_install_passes_version_pins
test_rustup_install_passes_channel_date
test_cargo_binstall_passes_version_pins

if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "All install-packages tests passed."
  exit 0
else
  echo "$TESTS_FAILED install-packages test(s) failed."
  exit 1
fi
