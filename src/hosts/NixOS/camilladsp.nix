# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared config definition is in src/modules/camilladsp.nix.
{ config, lib, pkgs, ... }:

{
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
}
