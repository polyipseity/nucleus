#!/usr/bin/env bash
# Behavioral tests for the POSIX package install scripts that converge to
# lockfile pins: install-bun-packages.sh, install-uv-tools.sh,
# init-rustup.sh, install-cargo-binstall-packages.sh, install-pi-packages.sh.
#
# Each test builds a fake repo root (src/lockfiles/lockfile.json) plus a
# $tmp/bin of stub tools that record the install spec they were handed, then
# runs the real script with NUCLEUS_REPO_ROOT pointing at the fake root so
# derive_repo_root resolves the lockfile.  We assert the version-pinned spec
# (pkg@version / pkg==version / channel-date / VCS) is passed to the installer.
#
# The desired-package list is the installers' trailing JSON argument, mirroring
# the entry shape of src/modules/packages/desired.json.
#
# Run with: bash tests/scripts/install-packages-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

PKG_DIR="$REPO_ROOT/src/scripts/packages"

# Desired-package lists handed to the installers, in the shape of
# src/modules/packages/desired.json entries (object with a named "name").
DESIRED_BUN='[{"name":"clawhub"},{"name":"@tobilu/qmd"}]'
DESIRED_UV='[{"name":"paddleocr","python":"3.11"}]'
DESIRED_CARGO_BINSTALL='[{"name":"nickel-lang-lsp"},{"name":"pay-respects"}]'
DESIRED_PI='[{"name":"pi-memory"},{"name":"pi-subagents"}]'

# Build a fake repo root with a lockfile and stub tool bin dir.  Prints the
# repo root path.  The lockfile mirrors the real shape for the sections the
# tests exercise (bun / uv / pi / rustup / cargo-binstall), including one VCS pin.
setup_fake_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src/lockfiles" "$dir/bin" "$dir/toolchain"
  cat >"$dir/src/lockfiles/lockfile.json" <<'EOF'
{
  "$schema": "./lockfile.schema.json",
  "bun": {
    "@earendil-works/pi-coding-agent": "0.73.1",
    "@tobilu/qmd": "2.8.3",
    "clawhub": "0.20.0"
  },
  "uv": {
    "yamllint": "1.35.1",
    "paddleocr": "3.6.0",
    "discord-music-rpc": {
      "rev": "bba71027a684db53f3fcde5adbd3d42627241a83",
      "source": "https://github.com/example/ext.discord-music-rpc"
    }
  },
  "pi": {
    "pi-memory": "0.4.2",
    "pi-subagents": "0.66.0"
  },
  "rustup": {
    "stable": "1.95.0"
  },
  "cargo-binstall": {
    "nickel-lang-lsp": "1.17.0",
    "pay-respects": "0.8.8"
  }
}
EOF
  cat >"$dir/src/lockfiles/lifecycle-allowlist.json" <<'LFALEOF'
{
  "$schema": "./lifecycle-allowlist.schema.json",
  "@tobilu/qmd": "Required: postinstall compiles native modules."
}
LFALEOF
  printf '%s\n' "$dir"
}

# Create the node-gyp toolchain stubs in their own directory so the tests can
# prove install-bun-packages.sh puts that directory on PATH for its children
# (a stub next to bun would make the assertion vacuous).
stub_node_gyp_toolchain() {
  local dir="$1" name
  for name in node-gyp python3 make; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/toolchain/$name"
    chmod +x "$dir/toolchain/$name"
  done
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

# Stub bun that also records the node-gyp toolchain environment it was given,
# so the tests can assert the activation wiring reaches the installer.
stub_bun_tool() {
  local dir="$1"
  cat >"$dir/bin/bun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS_DIR/calls-bun.txt"
{
  printf 'npm_config_node_gyp=%s\n' "${npm_config_node_gyp:-}"
  printf 'npm_config_python=%s\n' "${npm_config_python:-}"
  printf 'path=%s\n' "$PATH"
} >"$CALLS_DIR/calls-bun-env.txt"
exit 0
EOF
  chmod +x "$dir/bin/bun"
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
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  # No global package.json -> both desired packages are fresh installs.
  # WHY: HOME must point at a clean temp dir so the host's real
  # ~/.bun/install/global/package.json is not found by the script.
  # The stub bun exits 0 but doesn't create the binary, so we pre-create the
  # target binary to satisfy the post-install existence check.
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/clawhub" "$tmp/.bun/bin/qmd"
  if HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    "$DESIRED_BUN" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-bun-packages runs to completion"
  else
    assert_fail "install-bun-packages runs to completion" "exit code $?"
  fi
  if grep -qxF 'install -g --linker hoisted --ignore-scripts clawhub@0.20.0' "$tmp/calls-bun.txt"; then
    assert_pass "install-bun-packages pins clawhub@0.20.0 from lockfile"
  else
    assert_fail "install-bun-packages pins clawhub@0.20.0 from lockfile" "calls: $(cat "$tmp/calls-bun.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-bun.txt"
  rm -rf "$tmp"
}

test_bun_install_honours_binary_override() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  # @anthropic-ai/sandbox-runtime installs the 'srt' binary, not the unscoped
  # package basename.  Pre-creating only srt proves the post-install check
  # honours the declared override: without it the script would look for
  # 'sandbox-runtime' and abort.
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/srt"
  if HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    '[{"binary":"srt","name":"@anthropic-ai/sandbox-runtime"}]' >"$tmp/out.txt" 2>&1; then
    assert_pass "install-bun-packages accepts a declared binary override"
  else
    assert_fail "install-bun-packages accepts a declared binary override" "exit code $? out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  if grep -qxF 'install -g --linker hoisted --ignore-scripts @anthropic-ai/sandbox-runtime' "$tmp/calls-bun.txt"; then
    assert_pass "install-bun-packages installs the package named by the desired list"
  else
    assert_fail "install-bun-packages installs the package named by the desired list" "calls: $(cat "$tmp/calls-bun.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-bun.txt"
  rm -rf "$tmp"
}

test_bun_install_rejects_malformed_desired_list() {
  local tmp rc
  tmp="$(setup_fake_repo)"
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/clawhub" "$tmp/.bun/bin/qmd"
  rc=0
  HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    '{"clawhub":"0.20.0"}' >"$tmp/out.txt" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "install-bun-packages hard-errors on an unparseable desired list"
  else
    assert_fail "install-bun-packages hard-errors on an unparseable desired list" "exit 0 with an object instead of an array"
  fi
  if grep -q "could not parse the desired bun package list" "$tmp/out.txt"; then
    assert_pass "install-bun-packages names the unparseable desired list"
  else
    assert_fail "install-bun-packages names the unparseable desired list" "out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_uv_install_passes_version_pins() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool uv "$tmp"
  # uv tool list emits nothing -> both desired tools are fresh installs.
  if run_pkg_script install-uv-tools.sh "$tmp" \
    "$tmp/bin/uv" "$(command -v awk)" "$(command -v grep)" "$(command -v jq)" \
    "$DESIRED_UV" \
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

test_uv_install_applies_extras_suffix() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool uv "$tmp"
  # extras are applied as a pip-style suffix on the pinned distribution name.
  if run_pkg_script install-uv-tools.sh "$tmp" \
    "$tmp/bin/uv" "$(command -v awk)" "$(command -v grep)" "$(command -v jq)" \
    '[{"extras":"proxy","name":"yamllint"}]' \
    >"$tmp/out.txt" 2>&1; then
    assert_pass "install-uv-tools runs to completion with an extras entry"
  else
    assert_fail "install-uv-tools runs to completion with an extras entry" "exit code $?"
  fi
  if grep -qxF 'tool install --no-build yamllint==1.35.1[proxy]' "$tmp/calls-uv.txt"; then
    assert_pass "install-uv-tools appends the declared extras to the pinned spec"
  else
    assert_fail "install-uv-tools appends the declared extras to the pinned spec" "calls: $(cat "$tmp/calls-uv.txt" 2>/dev/null)"
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
  if grep -qxF 'toolchain install stable --no-self-update' "$tmp/calls-rustup.txt"; then
    assert_pass "init-rustup pins stable channel (no date suffix) from lockfile"
  else
    assert_fail "init-rustup pins stable channel (no date suffix) from lockfile" "calls: $(cat "$tmp/calls-rustup.txt" 2>/dev/null)"
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
    "$DESIRED_CARGO_BINSTALL" \
    "$tmp/bin/cargo" \
    "$tmp/bin/cargo-binstall" >"$tmp/out.txt" 2>&1; then
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

test_pi_install_keeps_npm_scheme_and_reads_settings() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_tool pi "$tmp"
  stub_tool bun "$tmp"
  # pi's authoritative registry: settings.json lists pi-memory already at the
  # pinned version, so only pi-subagents should be installed.  The install
  # record mirrors settings.json so both sources agree.
  mkdir -p "$tmp/.pi/agent/npm"
  printf '%s' '{"packages":["npm:pi-memory@0.4.2"]}' >"$tmp/.pi/agent/settings.json"
  printf '%s' '{"dependencies":{"pi-memory":"0.4.2"}}' >"$tmp/.pi/agent/npm/package.json"
  if HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    "$DESIRED_PI" "$tmp/bin" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-pi-packages runs to completion"
  else
    assert_fail "install-pi-packages runs to completion" "exit code $? out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  if grep -qxF 'install npm:pi-subagents@0.66.0 --no-approve' "$tmp/calls-pi.txt"; then
    assert_pass "install-pi-packages keeps the npm scheme on a pinned spec"
  else
    assert_fail "install-pi-packages keeps the npm scheme on a pinned spec" "calls: $(cat "$tmp/calls-pi.txt" 2>/dev/null)"
  fi
  if grep -q 'install npm:pi-memory' "$tmp/calls-pi.txt"; then
    assert_fail "install-pi-packages skips a package already at the pinned version" "calls: $(cat "$tmp/calls-pi.txt" 2>/dev/null)"
  else
    assert_pass "install-pi-packages skips a package already at the pinned version"
  fi
  rm -f "$tmp/calls-pi.txt"
  rm -rf "$tmp"
}

test_pi_install_hard_errors_on_failed_install() {
  local tmp rc
  tmp="$(setup_fake_repo)"
  stub_tool bun "$tmp"
  # A pi stub that always fails: convergence failure must abort the activation
  # instead of silently retrying on the next apply.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/pi"
  chmod +x "$tmp/bin/pi"
  mkdir -p "$tmp/.pi/agent/npm"
  printf '%s' '{"packages":[]}' >"$tmp/.pi/agent/settings.json"
  rc=0
  HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    '[{"name":"pi-subagents"}]' "$tmp/bin" >"$tmp/out.txt" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "install-pi-packages hard-errors when pi install fails"
  else
    assert_fail "install-pi-packages hard-errors when pi install fails" "exit 0 despite a failing pi install"
  fi
  if grep -q "install npm:pi-subagents@0.66.0' failed" "$tmp/out.txt"; then
    assert_pass "install-pi-packages names the failed install spec"
  else
    assert_fail "install-pi-packages names the failed install spec" "out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_pi_install_emits_a_git_spec_for_a_revision_pin() {
  local tmp rev
  tmp="$(setup_fake_repo)"
  stub_tool pi "$tmp"
  stub_tool bun "$tmp"
  rev="bba71027a684db53f3fcde5adbd3d42627241a83"
  # A VCS-shaped pi pin.  pi's parser understands "git:<url>#<rev>" and treats
  # "git+<url>#<rev>" as a local path, so the lockfile's git+ source prefix has
  # to be stripped when the spec is emitted.
  python3 -c "import json; p='$tmp/src/lockfiles/lockfile.json'; d=json.load(open(p)); d['pi']['pi-subagents']={'source':'git+https://github.com/example/pi-subagents','rev':'$rev'}; json.dump(d, open(p,'w'), indent=2)"
  mkdir -p "$tmp/.pi/agent/npm"
  printf '%s' '{"packages":[]}' >"$tmp/.pi/agent/settings.json"
  if HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    '[{"name":"pi-subagents"}]' "$tmp/bin" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-pi-packages runs with a revision pin"
  else
    assert_fail "install-pi-packages runs with a revision pin" "out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  if grep -qxF "install git:https://github.com/example/pi-subagents#$rev --no-approve" "$tmp/calls-pi.txt"; then
    assert_pass "install-pi-packages emits pi's git: source form for a revision pin"
  else
    assert_fail "install-pi-packages emits pi's git: source form for a revision pin" "calls: $(cat "$tmp/calls-pi.txt" 2>/dev/null)"
  fi
  # Already installed at the pinned revision: the rev appears in the recorded
  # dependency value, so a second apply must not reinstall.
  rm -f "$tmp/calls-pi.txt"
  printf '%s' "{\"dependencies\":{\"pi-subagents\":\"git+https://github.com/example/pi-subagents#$rev\"}}" >"$tmp/.pi/agent/npm/package.json"
  HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    '[{"name":"pi-subagents"}]' "$tmp/bin" >"$tmp/out2.txt" 2>&1 || true
  if [ -f "$tmp/calls-pi.txt" ] && grep -q '^install ' "$tmp/calls-pi.txt"; then
    assert_fail "install-pi-packages skips a revision pin already at the pinned rev" "calls: $(cat "$tmp/calls-pi.txt" 2>/dev/null)"
  else
    assert_pass "install-pi-packages skips a revision pin already at the pinned rev"
  fi
  rm -rf "$tmp"
}

test_pi_install_puts_bun_on_the_child_path() {
  local tmp bun_dir
  tmp="$(setup_fake_repo)"
  # bun lives in a directory that is not a PATH entry of the harness, so the
  # only way the pi child can resolve the bare command "bun" it spawns for
  # npm: installs is the installer prepending its explicit bun argument.
  bun_dir="$tmp/bun-only"
  mkdir -p "$bun_dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bun_dir/bin/bun"
  chmod +x "$bun_dir/bin/bun"
  # pi records the bun it can resolve; an empty record is the spawn ENOENT
  # failure this test guards against.
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS_DIR/calls-pi.txt"
printf 'resolved=%s\n' "$(command -v bun || true)" >> "$CALLS_DIR/calls-pi-bun.txt"
exit 0
EOF
  chmod +x "$tmp/bin/pi"
  mkdir -p "$tmp/.pi/agent/npm"
  printf '%s' '{"packages":[]}' >"$tmp/.pi/agent/settings.json"
  if HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    '[{"name":"pi-subagents"}]' "$bun_dir/bin" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-pi-packages runs with bun only in the passed bin dir"
  else
    assert_fail "install-pi-packages runs with bun only in the passed bin dir" "out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  if grep -qxF "resolved=$bun_dir/bin/bun" "$tmp/calls-pi-bun.txt"; then
    assert_pass "install-pi-packages puts the passed bun first on the child PATH"
  else
    assert_fail "install-pi-packages puts the passed bun first on the child PATH" "record: $(cat "$tmp/calls-pi-bun.txt" 2>/dev/null)"
  fi
  # Negative proof: an unusable bun must abort here instead of reaching pi,
  # where it surfaces as an opaque spawn ENOENT.
  if HOME="$tmp" run_pkg_script install-pi-packages.sh "$tmp" \
    "$(command -v jq)" "$tmp/bin/pi" "$(command -v awk)" \
    '[{"name":"pi-subagents"}]' "$tmp/absent" >"$tmp/out2.txt" 2>&1; then
    assert_fail "install-pi-packages hard-errors on an unusable bun" "exit 0 without a runnable bun"
  else
    assert_pass "install-pi-packages hard-errors on an unusable bun"
  fi
  rm -rf "$tmp"
}

test_bun_lifecycle_allowlist() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  # @tobilu/qmd is in the lifecycle-allowlist -> should NOT use --ignore-scripts.
  # clawhub is NOT in the allowlist -> should use --ignore-scripts.
  # We need to add @tobilu/qmd to the lockfile for version pinning.
  python3 -c "import json; d=json.load(open(\"$tmp/src/lockfiles/lockfile.json\")); d[\"bun\"][\"@tobilu/qmd\"] = \"2.8.3\"; json.dump(d, open(\"$tmp/src/lockfiles/lockfile.json\", \"w\"), indent=2)"
  # Pre-create binaries for the post-install existence check.
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/clawhub" "$tmp/.bun/bin/qmd"
  if HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    "$DESIRED_BUN" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-bun-packages runs to completion with lifecycle-allowlist"
  else
    assert_fail "install-bun-packages runs to completion with lifecycle-allowlist" "exit code $?"
  fi
  # @tobilu/qmd: allowlisted -> no --ignore-scripts
  if grep -qxF 'install -g --linker hoisted @tobilu/qmd@2.8.3' "$tmp/calls-bun.txt"; then
    assert_pass "install-bun-packages omits --ignore-scripts for lifecycle-allowlisted @tobilu/qmd"
  else
    assert_fail "install-bun-packages omits --ignore-scripts for lifecycle-allowlisted @tobilu/qmd" "calls: $(cat "$tmp/calls-bun.txt" 2>/dev/null)"
  fi
  # clawhub: not allowlisted -> uses --ignore-scripts
  if grep -qxF 'install -g --linker hoisted --ignore-scripts clawhub@0.20.0' "$tmp/calls-bun.txt"; then
    assert_pass "install-bun-packages uses --ignore-scripts for non-allowlisted clawhub"
  else
    assert_fail "install-bun-packages uses --ignore-scripts for non-allowlisted clawhub" "calls: $(cat "$tmp/calls-bun.txt" 2>/dev/null)"
  fi
  rm -f "$tmp/calls-bun.txt"
  rm -rf "$tmp"
}

test_bun_install_exports_node_gyp_toolchain() {
  local tmp
  tmp="$(setup_fake_repo)"
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/clawhub" "$tmp/.bun/bin/qmd"
  if HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    "$DESIRED_BUN" >"$tmp/out.txt" 2>&1; then
    assert_pass "install-bun-packages runs with the node-gyp toolchain"
  else
    assert_fail "install-bun-packages runs with the node-gyp toolchain" "exit code $?"
  fi
  if grep -qxF "npm_config_node_gyp=$tmp/toolchain/node-gyp" "$tmp/calls-bun-env.txt"; then
    assert_pass "install-bun-packages exports npm_config_node_gyp to bun"
  else
    assert_fail "install-bun-packages exports npm_config_node_gyp to bun" "env: $(cat "$tmp/calls-bun-env.txt" 2>/dev/null)"
  fi
  if grep -qxF "npm_config_python=$tmp/toolchain/python3" "$tmp/calls-bun-env.txt"; then
    assert_pass "install-bun-packages exports npm_config_python to bun"
  else
    assert_fail "install-bun-packages exports npm_config_python to bun" "env: $(cat "$tmp/calls-bun-env.txt" 2>/dev/null)"
  fi
  if grep -q ":$tmp/toolchain:" "$tmp/calls-bun-env.txt"; then
    assert_pass "install-bun-packages puts the node-gyp toolchain directory on PATH"
  else
    assert_fail "install-bun-packages puts the node-gyp toolchain directory on PATH" "path: $(grep '^path=' "$tmp/calls-bun-env.txt" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_bun_install_hard_errors_without_toolchain() {
  local tmp rc
  tmp="$(setup_fake_repo)"
  stub_bun_tool "$tmp"
  stub_node_gyp_toolchain "$tmp"
  rm -f "$tmp/toolchain/make"
  mkdir -p "$tmp/.bun/bin" && touch "$tmp/.bun/bin/clawhub" "$tmp/.bun/bin/qmd"
  rc=0
  HOME="$tmp" run_pkg_script install-bun-packages.sh "$tmp" "$(command -v jq)" "$tmp/bin/bun" "$(command -v awk)" \
    "$tmp/toolchain/node-gyp" "$tmp/toolchain/python3" "$tmp/toolchain/make" \
    "$DESIRED_BUN" >"$tmp/out.txt" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_pass "install-bun-packages hard-errors when a node-gyp toolchain tool is missing"
  else
    assert_fail "install-bun-packages hard-errors when a node-gyp toolchain tool is missing" "exit 0 with make absent"
  fi
  if grep -q "make not found" "$tmp/out.txt"; then
    assert_pass "install-bun-packages names the missing toolchain tool"
  else
    assert_fail "install-bun-packages names the missing toolchain tool" "out: $(cat "$tmp/out.txt" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

section "install-packages" "lockfile pinning"
test_bun_install_passes_version_pins
test_bun_install_honours_binary_override
test_bun_install_rejects_malformed_desired_list
test_bun_install_exports_node_gyp_toolchain
test_bun_install_hard_errors_without_toolchain
test_bun_lifecycle_allowlist
test_uv_install_passes_version_pins
test_uv_install_applies_extras_suffix
test_rustup_install_passes_channel_date
test_cargo_binstall_passes_version_pins
test_pi_install_keeps_npm_scheme_and_reads_settings
test_pi_install_hard_errors_on_failed_install
test_pi_install_puts_bun_on_the_child_path
test_pi_install_emits_a_git_spec_for_a_revision_pin

finish_tests
