# shellcheck shell=sh
# Idempotently converges the declarative bun global package set.
# Tokens: __JQ_BIN__, __MANAGED_PREPEND_GUARD__, __MANAGED_APPEND_GUARD__,
#   __NIX_PROFILE_BIN_DIRS__ (replaced by Nix replaceStrings).
# Requires: bun on PATH.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

# _ibp_setup_path PREPEND_GUARD APPEND_GUARD NIX_PROFILE_BIN_DIRS
# Sets up PATH with managed bin directories and prepends nix profile dirs.
_ibp_setup_path() {
  _ibp_prepend_guard="$1"
  _ibp_append_guard="$2"
  shift 2

  PATH="${_ibp_prepend_guard}$PATH${_ibp_append_guard}"
  export PATH

  # Also prepend the nix profile bin directory, Home Manager profile bin
  # directory, and directly probe the nix store for common package bins.
  # After linkGeneration the profile symlinks exist, but the activation
  # shell's PATH may not include them.
  _nucleus_prepend_first_executable_dir bun "$@" || true  # undoc-supp: bun may not be in any profile dir; fallback follows.
}

# Call _ibp_setup_path with managed-path guard tokens.
_ibp_setup_path "__MANAGED_PREPEND_GUARD__" "__MANAGED_APPEND_GUARD__" "__NIX_PROFILE_BIN_DIRS__"

# If bun is still not found after _ibp_setup_path was called, search the
if ! command -v bun >/dev/null 2>&1; then
  # undoc-supp: nix store may not have bun yet on first apply; best-effort store probe.
  _bun_store_path="$(find /nix/store -name 'bun' -type f -print -quit 2>/dev/null || true)"
  if [ -n "$_bun_store_path" ] && [ -x "$_bun_store_path" ]; then
    _bun_store_dir="$(dirname "$_bun_store_path")"
    PATH="$_bun_store_dir:$PATH"
    export PATH
  fi
fi

# bun is provided by pkgs.bun in core.nix (baseSharedPackages).  Verify bun is
# now on PATH.  Fail fast if bun remains absent so the operator knows a full
# apply is needed.
if ! command -v bun >/dev/null 2>&1; then
  echo "bun: bun not found in PATH; cannot install bun global packages" >&2
  exit 1
fi

# Declarative desired-state list.  One package per line.
# Add a package name here to install it; remove it to trigger uninstall
# on the next apply.  Only add packages absent from nixpkgs and
# cargo-binstall (install preference: nixpkgs > cargo binstall > bun > uv).
_ibp_desired="$(mktemp)"
printf '%s\n' \
  'clawhub' \
  > "$_ibp_desired"

# Get actually installed global packages from bun's authoritative package
# registry (zap-style: remove any installed package absent from the desired
# list, regardless of prior managed state).  The global package.json is
# bun's canonical record of all globally-installed packages.
_ibp_global_json="$HOME/.bun/install/global/package.json"
_ibp_installed="$(mktemp)"
if [ -f "$_ibp_global_json" ]; then
  # undoc-supp: parse failure on a malformed or partially-written file treats the installed set as empty — safe because desired packages will simply be re-installed on the next run.
  __JQ_BIN__ -r '.dependencies // {} | keys[]' "$_ibp_global_json" > "$_ibp_installed" || true
fi

# Packages installed but not desired: zap-style removal.
# Mirrors homebrew cleanup = "zap": removes anything installed but absent
# from the declared desired set, regardless of how it was installed.
_ibp_to_remove="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  if ! grep -qxF "$_ibp_pkg" "$_ibp_desired"; then
    printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_remove"
  fi
done < "$_ibp_installed"

# Desired packages not yet in bun's global package.json, or whose binary
# is absent from ~/.bun/bin (re-install needed).  Binary name = last path
# component after '/' so @scope/name becomes name (bun uses the unscoped
# basename as the binary name).
_ibp_to_install="$(mktemp)"
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  _ibp_bin="${_ibp_pkg##*/}"
  if ! grep -qxF "$_ibp_pkg" "$_ibp_installed" || \
     { [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
       [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; }; then
    printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_install"
  fi
done < "$_ibp_desired"

# Remove packages no longer in the desired list.
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  echo "bun: removing $_ibp_pkg"
  if ! bun remove -g "$_ibp_pkg"; then
    echo "bun: 'bun remove -g $_ibp_pkg' failed" >&2
    rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
    exit 1
  fi
done < "$_ibp_to_remove"

# Install packages whose binary is absent from ~/.bun/bin.
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  echo "bun: installing $_ibp_pkg"
  if ! bun install -g --ignore-scripts "$_ibp_pkg"; then
    echo "bun: 'bun install -g $_ibp_pkg' failed" >&2
    rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
    exit 1
  fi
  _ibp_bin="${_ibp_pkg##*/}"
  if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
     [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
    echo "bun: $_ibp_pkg installed but binary '$_ibp_bin' not found in '$HOME/.bun/bin'" >&2
    rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
    exit 1
  fi
  echo "bun: $_ibp_pkg installed successfully"
done < "$_ibp_to_install"

rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
