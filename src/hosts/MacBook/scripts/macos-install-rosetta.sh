#!/usr/bin/env bash
# Installs Rosetta 2 once on Apple Silicon hosts if missing. `--agree-to-license` keeps
# activation non-interactive. Declarative Nix daemon support for x86_64-darwin is configured
# separately in base.nix via `nix.extraOptions` / `extra-platforms`.
#
# WHY: not provisioned via Homebrew. Rosetta 2 is a macOS system component, pre-installed on
# all Apple Silicon Macs. Homebrew casks declare `requires_rosetta` for x86_64 apps, but
# Rosetta itself is OS-managed and cannot be installed that way.
#
# WHY: the pkgutil probe suppresses both streams. pkgutil prints "No receipt for '...' found"
# to stderr when absent, which would read as a spurious warning during apply. The exit code
# alone determines presence; a real pkgutil failure surfaces as a failed softwareupdate call.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
  if ! /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
    die -l rosetta "installation failed."
  fi
fi
