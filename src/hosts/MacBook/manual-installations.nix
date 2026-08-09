# MacBook/manual-installations.nix — imperative installers for manual-only apps.
#
# This module is intentionally limited to software not managed by nixpkgs or
# Homebrew. Keep install/uninstall logic for each manual package here.
#
# WHY: postActivation.text, not a custom script name:
#   nix-darwin (rev 8c62fba) assembles only a hardcoded fixed list of named
#   scripts into the activate binary; custom names are silently ignored.
#   postActivation is the correct extension point for scripts that must run
#   after openssh.  lib.mkBefore prepends before the HM activation call.
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
in
{
  # ---------------------------------------------------------------------------
  # configure-rosetta (postActivation fragment)
  # Installs Rosetta 2 once on Apple Silicon hosts if it is not already
  # present. `--agree-to-license` keeps activation non-interactive.
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''"${activationBundle}/src/hosts/MacBook/scripts/macos-install-rosetta.sh"'';
}
