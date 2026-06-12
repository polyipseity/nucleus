# hosts/MacBook/camillagui-backend.nix — CamillaDSP web GUI service on macOS.
#
# Serves the CamillaDSP configuration web interface on port 5005 (127.0.0.1).
# Communicates with the local CamillaDSP instance via its websocket API.
args@{
  config,
  lib,
  pkgs,
  ...
}:

let
  services = args.users.${args.username}.services or { };
  userEnable = services."camillagui-backend".enable or true;
in
{
  config = lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
    nucleus.httpsProxy.virtualHosts.camillagui = {
      listenPort = 5006;
      upstreamPort = 5005;
    };

    launchd.agents."camillagui-backend" = {
      serviceConfig = {
        Label = "local.camillagui-backend";
        ProgramArguments = [
          "/usr/bin/env"
          "camillagui-backend"
          "-c"
          "${config.users.users.${args.username}.home}/.config/camillagui-backend/config.yml"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${
          config.users.users.${args.username}.home
        }/Library/Logs/nucleus/camillagui-backend/stdout.log";
        StandardErrorPath = "${
          config.users.users.${args.username}.home
        }/Library/Logs/nucleus/camillagui-backend/stderr.log";
      };
    };
  };
}
