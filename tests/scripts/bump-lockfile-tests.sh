#!/usr/bin/env bash
# Behavioral tests for scripts/bump-lockfile.sh: --verify stability, no-change
# write skipping (.updated is stamped only when a section changed),
# --list-sections / --sections validation, GitHub scalar updaters, no-updater
# sections, and vm-setup sub-section selection.
#
# Run with: bash tests/scripts/bump-lockfile-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

BUMP_LOCKFILE_SCRIPT="$REPO_ROOT/scripts/bump-lockfile.sh"

# Create a fake repo ($tmp/src/lockfiles/lockfile.json) plus an empty $tmp/bin
# for stub tools; print the repo root. The fixture is a trimmed lockfile
# (2-space jq indent, trailing newline) mirroring the shape of
# src/lockfiles/lockfile.json for the sections the tests exercise (scalar pins
# and vm-setup included).
setup_fake_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src/lockfiles" "$dir/bin"
  cat >"$dir/src/lockfiles/lockfile.json" <<'EOF'
{
  "$schema": "./lockfile.schema.json",
  "bun": {
    "fixture-pkg": "1.0.0"
  },
  "camilladsp": "1.0.0",
  "cargo-binstall": {
    "fixture-tool": "0.1.0"
  },
  "updated": "2026-08-02T07:16:01Z",
  "vm-setup": {
    "nixos-iso": {
      "aarch64-linux": {
        "url": "https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-aarch64-linux.iso",
        "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
    },
    "tart-images": {
      "sequoia": {
        "image": "ghcr.io/cirruslabs/macos-sequoia-base",
        "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
    }
  }
}
EOF
  printf '%s\n' "$dir"
}

# Run the real script against a fake repo root with stub PATH prepended, so
# fake tools win while real jq/date stay reachable.
run_bump_lockfile() {
  local repo_root="$1"
  shift
  NUCLEUS_REPO_ROOT="$repo_root" PATH="$repo_root/bin:$PATH" \
    "$BUMP_LOCKFILE_SCRIPT" "$@"
}

test_list_sections_prints_all() {
  local tmp
  tmp="$(setup_fake_repo)"
  if run_bump_lockfile "$tmp" --list-sections >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --list-sections exits 0"
  else
    assert_fail "bump-lockfile --list-sections exits 0" "exit code $?"
  fi
  cat >"$tmp/expected.txt" <<'EOF'
bun
camilladsp
camillagui-backend
cargo
cargo-binstall
homebrew
homebrew.brews
homebrew.casks
homebrew.masApps
ollama
pwsh
rustup
sccache
scoop
source-builds
starship
uv
version
vm-setup
vm-setup.nixos-iso
vm-setup.tart-images
vm-setup.windows
vscode
winget
EOF
  if diff -u "$tmp/expected.txt" "$tmp/out.txt" >"$tmp/diff.txt" 2>&1; then
    assert_pass "bump-lockfile --list-sections prints the 24 canonical names"
  else
    assert_fail "bump-lockfile --list-sections prints the 24 canonical names" "diff: $(head -1 "$tmp/diff.txt")"
  fi
  rm -rf "$tmp"
}

test_sections_rejects_unknown() {
  local tmp
  tmp="$(setup_fake_repo)"
  if run_bump_lockfile "$tmp" --sections bogus >"$tmp/out.txt" 2>&1; then
    assert_fail "bump-lockfile --sections bogus exits 1" "expected non-zero exit"
  else
    assert_pass "bump-lockfile --sections bogus exits 1"
  fi
  if grep -q "unknown section 'bogus' (valid: bun,camilladsp," "$tmp/out.txt"; then
    assert_pass "bump-lockfile --sections bogus reports the unknown section"
  else
    assert_fail "bump-lockfile --sections bogus reports the unknown section" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_scalar_section_updates_from_github() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl-response.json" <<'EOF'
{"tag_name": "v4.1.3"}
EOF
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/curl-response.json"
EOF
  chmod +x "$tmp/bin/curl"

  if run_bump_lockfile "$tmp" --sections camilladsp >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile camilladsp GitHub release path exits 0"
  else
    assert_fail "bump-lockfile camilladsp GitHub release path exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.camilladsp' "$tmp/src/lockfiles/lockfile.json")" = "4.1.3" ]; then
    assert_pass "bump-lockfile camilladsp updates the pinned scalar"
  else
    assert_fail "bump-lockfile camilladsp updates the pinned scalar" "got $(jq -r '.camilladsp' "$tmp/src/lockfiles/lockfile.json")"
  fi
  if grep -q 'updating camilladsp.camilladsp from 1.0.0 to 4.1.3' "$tmp/out.txt"; then
    assert_pass "bump-lockfile camilladsp reports the update"
  else
    assert_fail "bump-lockfile camilladsp reports the update" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_no_updater_section_is_skipped() {
  local tmp before after
  tmp="$(setup_fake_repo)"
  before="$(cat "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections version >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --sections version (no updater) exits 0"
  else
    assert_fail "bump-lockfile --sections version (no updater) exits 0" "exit code $?"
  fi
  after="$(cat "$tmp/src/lockfiles/lockfile.json")"
  if [ "$before" = "$after" ]; then
    assert_pass "bump-lockfile --sections version leaves the lockfile unchanged"
  else
    assert_fail "bump-lockfile --sections version leaves the lockfile unchanged" "file content changed"
  fi
  if grep -q 'has no updater' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --sections version warns about the manual section"
  else
    assert_fail "bump-lockfile --sections version warns about the manual section" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_vm_setup_subsection_runs_alone() {
  local tmp
  tmp="$(setup_fake_repo)"
  # Stub curl with a redirect location header plus a checksum body so the
  # nixos-iso block resolves a URL and digest locally (no real network).
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'location: https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-aarch64-linux.iso' \
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
EOF
  chmod +x "$tmp/bin/curl"

  if run_bump_lockfile "$tmp" --sections vm-setup.nixos-iso >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --sections vm-setup.nixos-iso exits 0"
  else
    assert_fail "bump-lockfile --sections vm-setup.nixos-iso exits 0" "exit code $?"
  fi
  if grep -q 'updating vm-setup.nixos-iso.aarch64-linux' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --sections vm-setup.nixos-iso updates the ISO pin"
  else
    assert_fail "bump-lockfile --sections vm-setup.nixos-iso updates the ISO pin" "output: $(head -1 "$tmp/out.txt")"
  fi
  if [ "$(jq -r '.["vm-setup"]["nixos-iso"]["aarch64-linux"].digest' "$tmp/src/lockfiles/lockfile.json")" = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]; then
    assert_pass "bump-lockfile --sections vm-setup.nixos-iso writes the new digest"
  else
    assert_fail "bump-lockfile --sections vm-setup.nixos-iso writes the new digest" "got $(jq -r '.["vm-setup"]["nixos-iso"]["aarch64-linux"].digest' "$tmp/src/lockfiles/lockfile.json")"
  fi
  if grep -q 'GHCR' "$tmp/out.txt"; then
    assert_fail "bump-lockfile --sections vm-setup.nixos-iso does not run tart-images" "GHCR message present"
  else
    assert_pass "bump-lockfile --sections vm-setup.nixos-iso does not run tart-images"
  fi
  rm -rf "$tmp"
}

test_vm_setup_parent_selects_children() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'location: https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-aarch64-linux.iso' \
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
EOF
  chmod +x "$tmp/bin/curl"

  if run_bump_lockfile "$tmp" --sections vm-setup >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --sections vm-setup (parent) exits 0"
  else
    assert_fail "bump-lockfile --sections vm-setup (parent) exits 0" "exit code $?"
  fi
  if grep -q 'updating vm-setup.nixos-iso.aarch64-linux' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --sections vm-setup runs the nixos-iso child"
  else
    assert_fail "bump-lockfile --sections vm-setup runs the nixos-iso child" "output: $(head -1 "$tmp/out.txt")"
  fi
  if grep -q 'could not get GHCR token' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --sections vm-setup runs the tart-images child"
  else
    assert_fail "bump-lockfile --sections vm-setup runs the tart-images child" "GHCR token message missing"
  fi
  if grep -q 'updating bun' "$tmp/out.txt"; then
    assert_fail "bump-lockfile --sections vm-setup does not run unrelated sections" "bun updated"
  else
    assert_pass "bump-lockfile --sections vm-setup does not run unrelated sections"
  fi
  rm -rf "$tmp"
}

test_verify_passes_on_unchanged_fixture() {
  local tmp
  tmp="$(setup_fake_repo)"
  # cargo-binstall is now live, so stub curl with the pinned version to keep
  # this test hermetic (no real network); same version => no change.
  cat >"$tmp/bin/curl-response.json" <<'EOF'
{"crate":{"max_stable_version":"0.1.0"},"versions":[{"num":"0.1.0"}]}
EOF
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/curl-response.json"
EOF
  chmod +x "$tmp/bin/curl"
  if run_bump_lockfile "$tmp" --sections cargo-binstall --verify >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --verify exits 0 on unchanged fixture"
  else
    assert_fail "bump-lockfile --verify exits 0 on unchanged fixture" "exit code $?"
  fi
  if grep -q 'up to date' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --verify reports up to date"
  else
    assert_fail "bump-lockfile --verify reports up to date" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_verify_fails_on_section_diff() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '2.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"

  if run_bump_lockfile "$tmp" --sections bun --verify >"$tmp/out.txt" 2>&1; then
    assert_fail "bump-lockfile --verify exits 1 on section diff" "expected non-zero exit"
  else
    assert_pass "bump-lockfile --verify exits 1 on section diff"
  fi
  if grep -q '2\.0\.0' "$tmp/out.txt"; then
    assert_pass "bump-lockfile --verify diff shows the version change"
  else
    assert_fail "bump-lockfile --verify diff shows the version change" "output: $(head -1 "$tmp/out.txt")"
  fi
  if grep -q '"updated"' "$tmp/out.txt"; then
    assert_fail "bump-lockfile --verify diff has no updated-timestamp change" "updated line in diff"
  else
    assert_pass "bump-lockfile --verify diff has no updated-timestamp change"
  fi
  rm -rf "$tmp"
}

test_no_change_run_writes_nothing() {
  local tmp before after
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '1.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"
  before="$(cat "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections bun >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile no-change run exits 0"
  else
    assert_fail "bump-lockfile no-change run exits 0" "exit code $?"
  fi
  after="$(cat "$tmp/src/lockfiles/lockfile.json")"
  if [ "$before" = "$after" ]; then
    assert_pass "bump-lockfile no-change run leaves file byte-identical"
  else
    assert_fail "bump-lockfile no-change run leaves file byte-identical" "file content changed"
  fi
  if grep -q 'no changes' "$tmp/out.txt"; then
    assert_pass "bump-lockfile no-change run reports no changes"
  else
    assert_fail "bump-lockfile no-change run reports no changes" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_change_run_writes_and_stamps_updated() {
  local tmp new_updated old_updated
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '2.0.0\n'
EOF
  chmod +x "$tmp/bin/npm"
  old_updated="$(jq -r '.updated' "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections bun >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile change run exits 0"
  else
    assert_fail "bump-lockfile change run exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.bun["fixture-pkg"]' "$tmp/src/lockfiles/lockfile.json")" = "2.0.0" ]; then
    assert_pass "bump-lockfile change run updates the bun key"
  else
    assert_fail "bump-lockfile change run updates the bun key" "got $(jq -r '.bun["fixture-pkg"]' "$tmp/src/lockfiles/lockfile.json")"
  fi
  new_updated="$(jq -r '.updated' "$tmp/src/lockfiles/lockfile.json")"
  if [ "$new_updated" != "$old_updated" ]; then
    assert_pass "bump-lockfile change run stamps a fresh updated"
  else
    assert_fail "bump-lockfile change run stamps a fresh updated" "updated unchanged: $new_updated"
  fi
  if [[ "$new_updated" > "$old_updated" ]] || [ "$new_updated" = "$old_updated" ]; then
    assert_pass "bump-lockfile change run stamps updated >= old lexically"
  else
    assert_fail "bump-lockfile change run stamps updated >= old lexically" "new $new_updated < old $old_updated"
  fi
  if grep -q 'wrote' "$tmp/out.txt"; then
    assert_pass "bump-lockfile change run reports the write"
  else
    assert_fail "bump-lockfile change run reports the write" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_cargo_binstall_updates_from_crates_io_api() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl-response.json" <<'EOF'
{"crate":{"max_stable_version":"2.0.0"},"versions":[{"num":"2.0.0"}]}
EOF
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/curl-response.json"
EOF
  chmod +x "$tmp/bin/curl"

  if run_bump_lockfile "$tmp" --sections cargo-binstall >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile cargo-binstall API path exits 0"
  else
    assert_fail "bump-lockfile cargo-binstall API path exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")" = "2.0.0" ]; then
    assert_pass "bump-lockfile cargo-binstall API path updates the pinned crate"
  else
    assert_fail "bump-lockfile cargo-binstall API path updates the pinned crate" "got $(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")"
  fi
  if grep -q 'updating cargo-binstall.fixture-tool from 0.1.0 to 2.0.0' "$tmp/out.txt"; then
    assert_pass "bump-lockfile cargo-binstall API path reports the update"
  else
    assert_fail "bump-lockfile cargo-binstall API path reports the update" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_cargo_binstall_cargo_alias_selects_section() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl-response.json" <<'EOF'
{"crate":{"max_stable_version":"2.0.0"},"versions":[{"num":"2.0.0"}]}
EOF
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/curl-response.json"
EOF
  chmod +x "$tmp/bin/curl"

  if run_bump_lockfile "$tmp" --sections cargo >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile --sections cargo alias exits 0"
  else
    assert_fail "bump-lockfile --sections cargo alias exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")" = "2.0.0" ]; then
    assert_pass "bump-lockfile --sections cargo alias updates the cargo-binstall entry"
  else
    assert_fail "bump-lockfile --sections cargo alias updates the cargo-binstall entry" "got $(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")"
  fi
  rm -rf "$tmp"
}

test_cargo_binstall_falls_back_to_cargo_search() {
  local tmp
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$tmp/bin/curl"
  cat >"$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'fixture-tool = "2.0.0"    A fixture tool\n'
EOF
  chmod +x "$tmp/bin/cargo"

  if run_bump_lockfile "$tmp" --sections cargo-binstall >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile cargo-binstall cargo search fallback exits 0"
  else
    assert_fail "bump-lockfile cargo-binstall cargo search fallback exits 0" "exit code $?"
  fi
  if [ "$(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")" = "2.0.0" ]; then
    assert_pass "bump-lockfile cargo-binstall cargo search fallback updates the pinned crate"
  else
    assert_fail "bump-lockfile cargo-binstall cargo search fallback updates the pinned crate" "got $(jq -r '.["cargo-binstall"]["fixture-tool"]' "$tmp/src/lockfiles/lockfile.json")"
  fi
  rm -rf "$tmp"
}

test_cargo_binstall_warns_when_no_version_source() {
  local tmp before after
  tmp="$(setup_fake_repo)"
  cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$tmp/bin/curl"
  cat >"$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$tmp/bin/cargo"
  before="$(cat "$tmp/src/lockfiles/lockfile.json")"

  if run_bump_lockfile "$tmp" --sections cargo-binstall >"$tmp/out.txt" 2>&1; then
    assert_pass "bump-lockfile cargo-binstall both-fail exits 0"
  else
    assert_fail "bump-lockfile cargo-binstall both-fail exits 0" "exit code $?"
  fi
  after="$(cat "$tmp/src/lockfiles/lockfile.json")"
  if [ "$before" = "$after" ]; then
    assert_pass "bump-lockfile cargo-binstall both-fail leaves the lockfile unchanged"
  else
    assert_fail "bump-lockfile cargo-binstall both-fail leaves the lockfile unchanged" "file content changed"
  fi
  if grep -q 'no version source' "$tmp/out.txt"; then
    assert_pass "bump-lockfile cargo-binstall both-fail warns about missing sources"
  else
    assert_fail "bump-lockfile cargo-binstall both-fail warns about missing sources" "output: $(head -1 "$tmp/out.txt")"
  fi
  rm -rf "$tmp"
}

test_verify_passes_on_unchanged_fixture
test_verify_fails_on_section_diff
test_no_change_run_writes_nothing
test_change_run_writes_and_stamps_updated
test_cargo_binstall_updates_from_crates_io_api
test_cargo_binstall_cargo_alias_selects_section
test_cargo_binstall_falls_back_to_cargo_search
test_cargo_binstall_warns_when_no_version_source
test_list_sections_prints_all
test_sections_rejects_unknown
test_scalar_section_updates_from_github
test_no_updater_section_is_skipped
test_vm_setup_subsection_runs_alone
test_vm_setup_parent_selects_children

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
