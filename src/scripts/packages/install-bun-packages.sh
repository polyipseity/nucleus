# shellcheck shell=sh
# Idempotently converges the declarative bun global package set.
set -euo pipefail

_jq_bin="$1"
_bun_bin="$2"

# Add bun's directory to PATH so bun is callable and child processes
# can find it.
_bun_bin_dir="$(dirname "$_bun_bin")"
PATH="$_bun_bin_dir:$PATH"
export PATH

if [ ! -x "$_bun_bin" ]; then
  echo "bun: $_bun_bin not found in nix store; cannot install bun global packages" >&2
  exit 1
fi

# Declarative desired-state list.  One package per line.
# Add a package name here to install it; remove it to trigger uninstall
# on the next apply.  Only add packages absent from nixpkgs and
# cargo-binstall (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
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
  "$_jq_bin" -r '.dependencies // {} | keys[]' "$_ibp_global_json" > "$_ibp_installed" || true
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
  if ! "$_bun_bin" remove -g "$_ibp_pkg"; then
    echo "bun: '$_bun_bin remove -g $_ibp_pkg' failed" >&2
    rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
    exit 1
  fi
done < "$_ibp_to_remove"

# Install packages whose binary is absent from ~/.bun/bin.
while IFS= read -r _ibp_pkg; do
  [ -z "$_ibp_pkg" ] && continue
  echo "bun: installing $_ibp_pkg"
  if ! "$_bun_bin" install -g --ignore-scripts "$_ibp_pkg"; then
    echo "bun: '$_bun_bin install -g $_ibp_pkg' failed" >&2
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
