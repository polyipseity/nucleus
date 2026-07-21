# Managed cargo-binstall package convergence (install + zap).
# Consumes crate-description tokens at activation time.
#
# Cargo resolution: uses nixpkgs cargo directly (store-path arg).
# Runtime path probing (~/.cargo/bin) is prohibited.
#
# Install priority: nixpkgs > cargo binstall > cargo > bun > uv.
set -euo pipefail

_icp_jq_bin="$1"
_icp_gawk_bin="$2"
_icp_desired_crates_json="$3"
_icp_cargo_bin="$4"

# Prepend nixpkgs cargo's directory to PATH so `cargo` is available.
PATH="$PATH:${_icp_cargo_bin%/*}"
export PATH

# Desired crates as JSON array of crate names, e.g. ["crate1","crate2"].
# Empty array = no cargo-binstall-managed crates on this host.
_icp_desired="$(mktemp)"
printf '%s\n' "$_icp_desired_crates_json" | "$_icp_jq_bin" -r '.[]' > "$_icp_desired"

# Get actually installed crates from `cargo install --list` (zap-style).
# Output format: "crate-name vX.Y.Z:" on header lines; extract the
# crate name (first field) from lines matching that pattern.
_icp_installed="$(mktemp)"
# undoc-supp: cargo install --list may fail if ~/.cargo is uninitialised; empty installed set is correct — nothing to remove.
cargo install --list 2>/dev/null | "$_icp_gawk_bin" '/^[a-zA-Z0-9_-]+ v/{print $1}' > "$_icp_installed" || true

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
  if ! cargo uninstall "$_icp_crate"; then
    echo "cargo-binstall: 'cargo uninstall $_icp_crate' failed" >&2
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
