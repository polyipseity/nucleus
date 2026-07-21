# Rustup initialisation for POSIX hosts.
# Consumes Nix profile bin directory lists at activation time.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

# All remaining arguments are probe directories (nix system bin dirs and
# nix profile bin dirs), passed as individual arguments from the Nix template.
# Locate pkgs.rustup in the newly linked home-manager profile.  The
# activation shell PATH has not yet been updated to reflect the profile, so
# probe known profile bin directories in priority order.
# Each dir is a separate shell argument (properly split by the Nix template),
# so "$@" expands to one directory per argument for _nucleus_prepend_first_executable_dir.
# undoc-supp: rustup may not be in profile dir on first apply; fallback follows.
_nucleus_prepend_first_executable_dir rustup "$@" || true

# Fallback: direct nix-store probe when profile PATH resolution fails
# (e.g. on first apply before the home-manager profile symlink exists).
# Mirrors the proven pattern from install-bun-packages.sh.
if ! command -v rustup >/dev/null 2>&1; then
  # undoc-supp: need fallback when nix-store path has not been built yet
  _rustup_store_path="$(find /nix/store -name 'rustup' -type f -print -quit 2>/dev/null || true)"
  if [ -n "$_rustup_store_path" ] && [ -x "$_rustup_store_path" ]; then
    _rustup_store_dir="$(dirname "$_rustup_store_path")"
    PATH="$_rustup_store_dir:$PATH"
    export PATH
  fi
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup: rustup not found after profile link; skipping initialization" >&2
else
  # WHY none: forces every project to declare its toolchain via
  # rust-toolchain.toml; prevents silent use of a global stable and
  # matches Windows Invoke-RustupSetup.
  rustup default none
  echo "rustup: default toolchain set to none"

  # Install the stable toolchain so cargo +stable is available for
  # cargo-binstall compilation fallback and cargo install --list operations.
  # Mirrors Windows Invoke-RustupSetup desiredChannels=["stable"] behavior.
  if rustup toolchain list 2>/dev/null | grep -q "^stable"; then
    echo "rustup: stable toolchain already present"
  else
    echo "rustup: installing stable toolchain for cargo-binstall fallback"
    rustup toolchain install stable --no-self-update
  fi
fi
