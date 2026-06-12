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
  services = args.users.${config.home.username}.services or { };
  userEnable = services."camillagui-backend".enable or true;
in
{
  config = lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
    launchd.agents."camillagui-backend" = {
      enable = true;
      config = {
        Label = "local.camillagui-backend";
        ProgramArguments = [
          "/usr/bin/env"
          "camillagui-backend"
          "-c"
          "${config.home.homeDirectory}/.config/camillagui-backend/config.yml"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.nucleus.logging.logDir}/camillagui-backend/stdout.log";
        StandardErrorPath = "${config.nucleus.logging.logDir}/camillagui-backend/stderr.log";
      };
    };
  };
}
