# macbook/manual-installations.nix — imperative installers for manual-only apps.
#
# This module is intentionally limited to software not managed by nixpkgs or
# Homebrew. Keep install/uninstall logic for each manual package here.
#
# WHY postActivation.text, not a custom script name:
#   nix-darwin (rev 8c62fba) assembles only a hardcoded fixed list of named
#   scripts into the activate binary; custom names are silently ignored.
#   postActivation is the correct extension point for scripts that must run
#   after openssh.  lib.mkBefore prepends before the HM activation call.
{ lib, ... }:
{
  # ---------------------------------------------------------------------------
  # configureRosetta (postActivation fragment)
  # Installs Rosetta 2 once on Apple Silicon hosts if it is not already
  # present. `--agree-to-license` keeps activation non-interactive.
  #
  # pkgutil probe: stdout is suppressed (only checking exit status); stderr is
  # suppressed because pkgutil prints "No receipt for '...' found" to stderr
  # when the package is absent, which would appear as a spurious warning in
  # normal apply output.  The exit code alone determines presence; a real
  # pkgutil failure surfaces as a failed softwareupdate call below.
  #
  # Declarative Nix daemon support for x86_64-darwin is configured separately
  # in base.nix via `nix.extraOptions` / `extra-platforms`.
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- configureRosetta ------------------------------------------------------
    if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto > /dev/null 2>&1; then
      if ! /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
        echo "rosetta: installation failed." >&2
      fi
    fi
  '';
}
