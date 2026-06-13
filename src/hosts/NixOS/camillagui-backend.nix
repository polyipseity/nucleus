# hosts/NixOS/camillagui-backend.nix — CamillaDSP GUI systemd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared config definition is in src/modules/camillagui-backend.nix.
{ config, lib, pkgs, ... }:

{
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
}
