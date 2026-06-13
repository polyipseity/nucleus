# modules/camilladsp.nix — CamillaDSP audio processor config.
#
# Cross-platform shared module. Only defines config deployment here;
# service-manager-specific definitions (launchd/systemd) live in per-host
# files under src/hosts/{MacBook,NixOS}/camilladsp.nix.
# Config deployed via environment.etc.
{
  config,
  pkgs,
  ...
}:

{
  config = {
    environment.etc."camilladsp/config.yml" = {
      source = ./configs/camilladsp/config-${if pkgs.stdenv.isDarwin then "macos" else "linux"}.yml;
    };
  };
}
