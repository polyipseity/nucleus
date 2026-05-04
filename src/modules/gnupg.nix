# modules/gnupg.nix — Shared GnuPG runtime settings for non-Home-Manager hosts.
{ lib, pkgs, options, ... }:
lib.mkIf (
  pkgs.stdenv.isDarwin
  && options ? programs
  && options.programs ? gnupg
  && options.programs.gnupg ? agent
) {
  # Keep the nix-darwin GnuPG agent enabled so the runtime daemon follows the
  # same derivation line as the CLI tools installed from pkgs.
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
}
