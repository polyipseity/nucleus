# Rustup initialisation for POSIX hosts.
# Consumes rustup store path at activation time.
set -euo pipefail

_rustup_bin="$1"

# Add rustup's directory to PATH so the tool is available for
# subsequent operations that expect it on PATH.
_rustup_bin_dir="$(dirname "$_rustup_bin")"
PATH="$_rustup_bin_dir:$PATH"
export PATH

if [ ! -x "$_rustup_bin" ]; then
  echo "rustup: $_rustup_bin not found in nix store; skipping initialization" >&2
else
  # WHY none: forces every project to declare its toolchain via
  # rust-toolchain.toml; prevents silent use of a global stable and
  # matches Windows Invoke-RustupSetup.
  "$_rustup_bin" default none
  echo "rustup: default toolchain set to none"

  # Install the stable toolchain so cargo +stable is available for
  # cargo-binstall compilation fallback and cargo install --list operations.
  # Mirrors Windows Invoke-RustupSetup desiredChannels=["stable"] behavior.
  if "$_rustup_bin" toolchain list 2>/dev/null | grep -q "^stable"; then
    echo "rustup: stable toolchain already present"
  else
    echo "rustup: installing stable toolchain for cargo-binstall fallback"
    "$_rustup_bin" toolchain install stable --no-self-update
  fi
fi
