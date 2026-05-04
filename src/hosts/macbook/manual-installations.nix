# macbook/manual-installations.nix — imperative installers for manual-only apps.
#
# This module is intentionally limited to software not managed by nixpkgs or
# Homebrew. Keep install/uninstall logic for each manual package here.
{ ... }:
{
  # ---------------------------------------------------------------------------
  # configureRosetta
  # Installs Rosetta 2 once on Apple Silicon hosts if it is not already
  # present. `--agree-to-license` keeps activation non-interactive.
  #
  # Declarative Nix daemon support for x86_64-darwin is configured separately
  # in base.nix via `nix.extraOptions` / `extra-platforms`.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureRosetta.text = ''
    if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto > /dev/null 2>&1; then
      if ! /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
        echo "nucleus: Rosetta installation command failed." >&2
      fi
    fi
  '';

}
