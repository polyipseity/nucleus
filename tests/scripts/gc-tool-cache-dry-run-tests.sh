#!/usr/bin/env bash
# Pins that gc.sh --dry-run removes nothing from the tool caches.
#
# The tool-cache step already honours --dry-run: the dispatch table short-circuits
# on a dry_run branch before gc_tool_caches_if_available is ever called, so its
# find -exec rm -rf and cargo-cache are unreachable under --dry-run. This suite
# pins that ordering against a filesystem tree, so a refactor cannot move the
# clear ahead of the guard and silently start deleting caches on a preview run.
# It asserts on filesystem state, not on the dry_run message text, which
# gc-log-tests.sh already covers.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

GC_SH="$SCRIPT_DIR/../../scripts/gc.sh"

# seed_tool_cache_tree HOME: create one marker file inside each cache directory
# that gc_tool_caches_if_available clears, and print the markers as lines. Each
# marker sits inside a subdir so the step's own find -maxdepth 1 -exec rm -rf
# must remove the subdir before the marker file is reachable.
#
# The uv and cargo-binstall markers sit under the same platform_cache_root the
# step computes (scripts/gc.sh:419-422): Library/Caches on Darwin, and the
# XDG_CACHE_HOME that run_gc_with_env pins to <home>/caches elsewhere. Seeding
# only the macOS path would leave the real-run assertion failing on Linux,
# where the step clears <home>/caches instead.
seed_tool_cache_tree() { # <home>
  local _h="$1"
  local _platform_cache_root
  if [ "$(uname -s)" = "Darwin" ]; then
    _platform_cache_root="$_h/Library/Caches"
  else
    _platform_cache_root="$_h/caches"
  fi
  printf '%s\n' \
    "$_h/.bun/install/cache/marker" \
    "$_platform_cache_root/cargo-binstall/marker" \
    "$_h/.rustup/tmp/marker" \
    "$_platform_cache_root/uv/marker"
}

# gc_flags: every --no-*-gc flag, so the run touches only the tool-cache step.
gc_flags() {
  printf '%s\n' \
    --no-git-cache-gc --no-hm-gc --no-system-gc --no-nix-artifacts-gc \
    --no-nix-gc --no-duperemove-gc --no-ollama-gc --no-sccache-gc \
    --no-wallpaper-gc --no-vm-gc --no-log-gc --no-journald-gc --no-scoop-gc
}

run_gc_with_env() { # <home> <gc args...>
  local _h="$1"
  shift
  HOME="$_h" \
    CARGO_HOME="$_h/.cargo" \
    RUSTUP_HOME="$_h/.rustup" \
    XDG_CACHE_HOME="$_h/caches" \
    BUN_INSTALL_CACHE_DIR="$_h/.bun/install/cache" \
    NUCLEUS_REPO_ROOT="$_h" \
    bash "$GC_SH" "$@"
}

# ---- Test A: --dry-run leaves every seeded cache entry in place ----

test_dry_run_removes_nothing() {
  local home marker
  home="$(mktemp -d)"
  while IFS= read -r marker; do
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
  done < <(seed_tool_cache_tree "$home")

  # shellcheck disable=SC2046 # reason: gc_flags emits one flag per word and the flags carry no whitespace
  run_gc_with_env "$home" --dry-run $(gc_flags) >/dev/null

  local missing=""
  while IFS= read -r marker; do
    if [ ! -f "$marker" ]; then
      missing="$missing $marker"
    fi
  done < <(seed_tool_cache_tree "$home")

  if [ -z "$missing" ]; then
    assert_pass "gc.sh --dry-run removes no tool-cache entries"
  else
    assert_fail "gc-dry-run" "--dry-run removed:$missing"
  fi
  rm -rf "$home"
}

# ---- Test B: a real run clears them, so Test A is not inert ----

test_real_run_clears_entries() {
  local home marker
  home="$(mktemp -d)"
  while IFS= read -r marker; do
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
  done < <(seed_tool_cache_tree "$home")

  # --no-scoop-gc is POSIX-inert (Windows-only flag); it exists in gc_flags so the
  # flag list stays alphabetically whole. gc.sh reports the acceptance and exits 0.
  # shellcheck disable=SC2046 # reason: gc_flags emits one flag per word and the flags carry no whitespace
  run_gc_with_env "$home" $(gc_flags) >/dev/null

  local survivors=""
  while IFS= read -r marker; do
    if [ -f "$marker" ]; then
      survivors="$survivors $marker"
    fi
  done < <(seed_tool_cache_tree "$home")

  # The uv cache sits at platform_cache_root, which the uv marker
  # above seeds. Every marker must be gone: if any survives, the step did not
  # clear that directory and the dry-run assertion above would be passing only
  # because the step is inert.
  if [ -z "$survivors" ]; then
    assert_pass "a real gc.sh run clears every seeded tool-cache entry"
  else
    assert_fail "gc-real-run" "real run left:$survivors"
  fi
  rm -rf "$home"
}

section 1 "gc tool-cache dry-run tests"
echo ""

test_dry_run_removes_nothing
test_real_run_clears_entries

finish_tests
