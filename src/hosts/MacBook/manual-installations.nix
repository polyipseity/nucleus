# MacBook/manual-installations.nix: imperative installers for manual-only apps.
#
# Limited to software neither nixpkgs nor Homebrew manages.
#
# WHY: postActivation.text, not a custom script name. nix-darwin assembles only a
# hardcoded list of named scripts into the activate binary and silently ignores
# custom names. lib.mkBefore prepends before the HM activation call.
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
in
{
  # ---------------------------------------------------------------------------
  # configure-rosetta: `--agree-to-license` keeps activation non-interactive.
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''"${activationBundle}/src/hosts/MacBook/scripts/macos-install-rosetta.sh"'';
}
