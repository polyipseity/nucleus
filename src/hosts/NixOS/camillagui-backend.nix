# hosts/NixOS/camillagui-backend.nix — CamillaDSP GUI systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camillagui-backend/. Config is deployed by Home Manager in
# modules/home.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

{
  systemd.services.camillagui-backend = {
    description = "CamillaDSP web GUI";
    after = [
      "network-online.target"
      "camilladsp.service"
    ];
    wants = [
      "network-online.target"
      "camilladsp.service"
    ];
    serviceConfig = {
      Type = "simple";
      User = username;
      ExecStart = "${pkgs.camillagui-backend}/bin/camillagui-backend -c %h/.config/camillagui-backend/config.yml";
      Restart = "on-failure";
    };
    wantedBy = [ "default.target" ];
  };
}
