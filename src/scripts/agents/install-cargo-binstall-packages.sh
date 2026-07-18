# Managed cargo-binstall package convergence (install + zap).
# Consumes crate-description tokens at activation time.
# Expects set -eu and the symlink hardening lib to be sourced before this
# script runs.
set -eu

_icp_jq_bin='__JQ_BIN__'
_icp_gawk_bin='__GAWK_BIN__'

# Desired crates as JSON array of crate names, e.g. ["crate1","crate2"].
# Empty array = no cargo-binstall-managed crates on this host.
_icp_desired="$(mktemp)"
printf '%s\n' '__DESIRED_CRATES_JSON__' | "$_icp_jq_bin" -r '.[]' > "$_icp_desired"

# Probe ~/.cargo/bin (rustup shim location) first, then nix-profile /
# home-manager-profile bin directories as fallback.  initRustup runs
# before this step to ensure the stable toolchain is installed.
# undoc-supp: cargo may not be in any profile dir on first apply; fallback follows.
_nucleus_prepend_first_executable_dir cargo "$HOME/__CARGO_BIN_DIR__" __NIX_SYSTEM_BIN_DIRS__ __NIX_PROFILE_BIN_DIRS__ || true

# Guard: cargo is provided by rustup (stable toolchain) via ~/.cargo/bin;
# initRustup ensures stable is installed before this step runs.
# If cargo is absent after PATH probing, skip rather than failing the
# whole activation; nothing is installed by this step on POSIX hosts.
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo-binstall: cargo not found in PATH; skipping package management"
  rm -f "$_icp_desired"
else
  # Get actually installed crates from `cargo install --list` (zap-style).
  # Output format: "crate-name vX.Y.Z:" on header lines; extract the
  # crate name (first field) from lines matching that pattern.
  _icp_installed="$(mktemp)"
  # undoc-supp: cargo +stable install --list may fail if stable toolchain is missing or ~/.cargo is uninitialised; empty installed set is correct — nothing to remove.
  cargo +stable install --list 2>/dev/null | "$_icp_gawk_bin" '/^[a-zA-Z0-9_-]+ v/{print $1}' > "$_icp_installed" || true

  # Crates installed but not desired: zap-style removal.
  _icp_to_remove="$(mktemp)"
  while IFS= read -r _icp_crate; do
    [ -z "$_icp_crate" ] && continue
    if ! grep -qxF "$_icp_crate" "$_icp_desired"; then
      printf '%s\n' "$_icp_crate" >> "$_icp_to_remove"
    fi
  done < "$_icp_installed"

  # Desired crates not yet installed.
  _icp_to_install="$(mktemp)"
  while IFS= read -r _icp_crate; do
    [ -z "$_icp_crate" ] && continue
    if ! grep -qxF "$_icp_crate" "$_icp_installed"; then
      printf '%s\n' "$_icp_crate" >> "$_icp_to_install"
    fi
  done < "$_icp_desired"

  # Remove crates not in the desired list.
  while IFS= read -r _icp_crate; do
    [ -z "$_icp_crate" ] && continue
    echo "cargo-binstall: removing $_icp_crate"
    if ! cargo +stable uninstall "$_icp_crate"; then
      echo "cargo-binstall: 'cargo +stable uninstall $_icp_crate' failed" >&2
      rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
      exit 1
    fi
    echo "cargo-binstall: '$_icp_crate' removed"
  done < "$_icp_to_remove"

  # Install desired crates not currently installed.
  while IFS= read -r _icp_crate; do
    [ -z "$_icp_crate" ] && continue
    echo "cargo-binstall: installing $_icp_crate"
    if ! cargo-binstall --no-confirm "$_icp_crate"; then
      echo "cargo-binstall: 'cargo-binstall $_icp_crate' failed" >&2
      rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
      exit 1
    fi
    echo "cargo-binstall: '$_icp_crate' installed"
  done < "$_icp_to_install"

  if [ ! -s "$_icp_to_remove" ] && [ ! -s "$_icp_to_install" ]; then
    echo "cargo-binstall: all managed packages already converged — skipping"
  fi

  rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
fi
