# modules/camilladsp.nix — CamillaDSP audio processor.
#
# Cross-platform shared module. Runs as a system-wide service on all platforms.
# Config deployed via environment.etc; logs to systemLogDir.
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
      environment.etc."camilladsp/config.yml" = {
        source = ./configs/camilladsp/config-${if pkgs.stdenv.isDarwin then "macos" else "linux"}.yml;
      };
    }

    (mkIf pkgs.stdenv.isDarwin {
      launchd.daemons."camilladsp" = {
        serviceConfig = {
          Label = "local.camilladsp";
          ProgramArguments = [
            "${pkgs.camilladsp}/bin/camilladsp"
            "-o"
            "/etc/camilladsp/config.yml"
            "-p"
            "1234"
            "-w"
          ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "${systemLogDir}/camilladsp/stdout.log";
          StandardErrorPath = "${systemLogDir}/camilladsp/stderr.log";
        };
      };
    })

    (mkIf pkgs.stdenv.isLinux {
      systemd.services.camilladsp = {
        description = "CamillaDSP audio processor with websocket API";
        after = [ "network-online.target" "sound.target" ];
        wants = [ "network-online.target" "sound.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.camilladsp}/bin/camilladsp -o /etc/camilladsp/config.yml -p 1234 -w";
          Restart = "on-failure";
        };
        wantedBy = [ "default.target" ];
      };
    })
  ];
}
