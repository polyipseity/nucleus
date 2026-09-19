#!/usr/bin/env bash
# Layout tests: every writeNucleusShellApplication call site produces one
# identical $out layout — $out/scripts and $out/src are symlinks to the
# shared bundles, and the entry script is reachable at $out/<scriptName>.sh.
# This guards the uniform-layout refactor: no per-call-site divergence, no
# repo-root detection, no bundleDefault toggle.
#
# Also guards the script tree's input set: it must depend on the script
# directories only, never on the whole src/ tree (which would re-key the
# shared tree — and every app built from it — on any edit under src/).
#
# Representative packages:
#   - nucleus-gc            (scripts/-prefixed entry: scripts/gc)
#   - nucleus-apply         (src/-prefixed entry: src/scripts/apply)
#   nucleus-check         (pwsh subcommand: text= wrapper, no scriptName)
#   - nucleus-check         (pwsh subcommand: text= wrapper, no scriptName)
#
# Dependencies: nix (with flakes enabled), jq.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

cd "$REPO_ROOT"

# Packages under test, with their expected entry script path under $out.
declare -a LAYOUT_PACKAGES=(
  nucleus-apply
  nucleus-ai
  nucleus-bootstrap
  nucleus-check
  nucleus-config
  nucleus-utils
  nucleus-gc
  nucleus-svc
  nucleus-test
  nucleus-update
  nucleus-vm
  nucleus-cloud
)
# Non-text packages: entry script reachable at $out/<scriptName>.sh.
declare -A ENTRY_SCRIPT=(
  ["nucleus-apply"]=src/scripts/apply.sh
  ["nucleus-ai"]=scripts/ai.sh
  ["nucleus-bootstrap"]=scripts/bootstrap.sh
  ["nucleus-check"]=scripts/check.sh
  ["nucleus-config"]=scripts/config.sh
  ["nucleus-utils"]=scripts/utils.sh
  ["nucleus-gc"]=scripts/gc.sh
  ["nucleus-svc"]=scripts/svc.sh
  ["nucleus-test"]=scripts/test.sh
  ["nucleus-update"]=scripts/update.sh
  ["nucleus-vm"]=scripts/vm.sh
  ["nucleus-cloud"]=scripts/cloud.sh
)
# Text-mode packages: script is inlined into $out/bin/nucleus-<name> (no
# $out/<scriptName>.sh). The uniform $out/scripts + $out/src still apply.
# The merged command surface has no text-mode packages.
declare -A TEXT_PKG=(

)

echo "Building ${#LAYOUT_PACKAGES[@]} nucleus packages..."

BUILD_JSON=$(nix build --no-link --json \
  "${LAYOUT_PACKAGES[@]/#/./src#}")
echo "Build complete."

declare -a PKG_PATHS
while IFS=$'\t' read -r _idx _path; do
  PKG_PATHS[_idx]="$_path"
done < <(echo "$BUILD_JSON" | jq -r 'to_entries | .[] | [.key, .value.outputs.out] | @tsv')

pkg_path() {
  local pkg="$1"
  local idx=-1
  for i in "${!LAYOUT_PACKAGES[@]}"; do
    if [ "${LAYOUT_PACKAGES[$i]}" = "$pkg" ]; then
      idx=$i
      break
    fi
  done
  if [ "$idx" -lt 0 ]; then
    echo "error: unknown package $pkg" >&2
    return 1
  fi
  printf '%s' "${PKG_PATHS[$idx]}"
}

test_layout() {
  local pkg="$1"
  local out
  out=$(pkg_path "$pkg") || return 1
  local entry="${ENTRY_SCRIPT[$pkg]:-}"

  # $out/scripts and $out/src must both exist and be symlinks.
  if [ -L "$out/scripts" ] && [ -e "$out/scripts" ]; then
    assert_pass "$pkg: \$out/scripts is a symlink"
  else
    assert_fail "$pkg: \$out/scripts is a symlink" "missing or not a symlink"
    return
  fi

  if [ -L "$out/src" ] && [ -e "$out/src" ]; then
    assert_pass "$pkg: \$out/src is a symlink"
  else
    assert_fail "$pkg: \$out/src is a symlink" "missing or not a symlink"
    return
  fi

  # Entry script reachable at $out/<scriptName>.sh (non-text packages).
  if [ -n "${TEXT_PKG[$pkg]:-}" ]; then
    if [ -f "$out/bin/$pkg" ]; then
      assert_pass "$pkg: text-mode entry at \$out/bin/$pkg"
    else
      assert_fail "$pkg: text-mode entry at \$out/bin/$pkg" "missing"
      return
    fi
  elif [ -n "${entry:-}" ] && [ -f "$out/$entry" ]; then
    assert_pass "$pkg: entry script at \$out/$entry"
  else
    assert_fail "$pkg: entry script at \$out/$entry" "missing"
    return
  fi

  # Host-script regression: scripts/lib/lib must resolve from $out/src/scripts
  # (the shared script-tree), so SCRIPT_DIR/../src/scripts/lib/lib.sh works.
  if [ -e "$out/src/scripts/lib/lib.sh" ]; then
    assert_pass "$pkg: \$out/src/scripts/lib/lib.sh present"
  else
    assert_fail "$pkg: \$out/src/scripts/lib/lib.sh present" "missing"
  fi
}

section 1 "Uniform writeNucleusShellApplication \$out layout"
for pkg in "${LAYOUT_PACKAGES[@]}"; do
  test_layout "$pkg"
done

section 2 "Script tree input set"

test_script_tree_inputs() {
  local app_out tree tree_drv refs
  app_out=$(pkg_path nucleus-gc) || return 1
  # $out/src is a symlink to <nucleus-script-tree>/src; the deriver of that
  # store path exposes the derivation's inputs.
  tree="$(readlink -f "$app_out/src")"
  tree_drv="$(nix-store -q --deriver "$(dirname "$tree")")"
  refs="$(nix-store -q --references "$tree_drv")"

  if printf '%s\n' "$refs" | grep -qE '/[0-9a-z]{32}-src$'; then
    assert_fail "script tree has no whole-src/ input" "$(printf '%s\n' "$refs" | grep -E '/[0-9a-z]{32}-src$')"
  else
    assert_pass "script tree has no whole-src/ input"
  fi

  # Host script trees are still bundled, and nothing outside the script trees is.
  local host
  for host in MacBook NixOS; do
    if [ -d "$tree/hosts/$host/scripts" ]; then
      assert_pass "script tree bundles src/hosts/$host/scripts"
    else
      assert_fail "script tree bundles src/hosts/$host/scripts" "missing"
    fi
  done

  if [ -e "$tree/modules" ]; then
    assert_fail "script tree does not bundle non-script src/ trees" "src/modules present"
  else
    assert_pass "script tree does not bundle non-script src/ trees"
  fi
}

test_script_tree_inputs

# --- Summary -----------------------------------------------------------------
finish_tests
