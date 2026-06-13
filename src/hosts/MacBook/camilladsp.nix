# hosts/MacBook/camilladsp.nix — CamillaDSP launchd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared config definition is in src/modules/camilladsp.nix.
{ config, lib, pkgs, ... }:

let
  systemLogDir = config.nucleus.logging.systemLogDir;
in
{
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
}
