# modules/camillagui-backend.nix — CamillaDSP web GUI config.
#
# Cross-platform shared module. Only defines config deployment and HTTPS proxy
# here; service-manager-specific definitions (launchd/systemd) live in per-host
# files under src/hosts/{MacBook,NixOS}/camillagui-backend.nix.
{
  config,
  pkgs,
  ...
}:

{
  config = {
    nucleus.httpsProxy.virtualHosts.camillagui = {
      listenPort = 5006;
      upstreamPort = 5005;
    };

    environment.etc."camillagui-backend/config.yml" = {
      source = ./configs/camillagui-backend/config-${if pkgs.stdenv.isDarwin then "macos" else "linux"}.yml;
    };
  };
}
