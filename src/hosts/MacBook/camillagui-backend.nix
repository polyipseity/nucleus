# hosts/MacBook/camillagui-backend.nix — CamillaDSP GUI launchd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared config definition is in src/modules/camillagui-backend.nix.
{ config, lib, pkgs, ... }:

let
  systemLogDir = config.nucleus.logging.systemLogDir;
in
{
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
}
