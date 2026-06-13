# modules/camillagui-backend.nix — CamillaDSP web GUI.
#
# Cross-platform shared module. Runs as a system-wide service on all platforms.
# Config deployed via environment.etc; DSP state at system paths;
# logs to systemLogDir.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge;
  systemLogDir = config.nucleus.logging.systemLogDir;
in
{
  config = mkMerge [
    {
      nucleus.httpsProxy.virtualHosts.camillagui = {
        listenPort = 5006;
        upstreamPort = 5005;
      };
    }

    {
      environment.etc."camillagui-backend/config.yml" = {
        source = ./configs/camillagui-backend/config-${if pkgs.stdenv.isDarwin then "macos" else "linux"}.yml;
      };
    }

    (mkIf pkgs.stdenv.isDarwin {
      launchd.daemons."camillagui-backend" = {
        serviceConfig = {
          Label = "local.camillagui-backend";
          ProgramArguments = [
            "${pkgs.camillagui-backend}/bin/camillagui-backend"
            "-c"
            "/etc/camillagui-backend/config.yml"
          ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "${systemLogDir}/camillagui-backend/stdout.log";
          StandardErrorPath = "${systemLogDir}/camillagui-backend/stderr.log";
        };
      };
    })

    (mkIf pkgs.stdenv.isLinux {
      systemd.services.camillagui-backend = {
        description = "CamillaDSP web GUI";
        after = [ "network-online.target" "camilladsp.service" ];
        wants = [ "network-online.target" "camilladsp.service" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.camillagui-backend}/bin/camillagui-backend -c /etc/camillagui-backend/config.yml";
          Restart = "on-failure";
        };
        wantedBy = [ "default.target" ];
      };
    })
  ];
}
