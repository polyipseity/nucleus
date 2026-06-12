# hosts/NixOS/camillagui-backend.nix — CamillaDSP web GUI service on NixOS.
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
  config = lib.mkIf (pkgs.stdenv.isLinux && userEnable) {
    nucleus.httpsProxy.virtualHosts.camillagui = { listenPort = 5006; upstreamPort = 5005; };

    systemd.user.services."camillagui-backend" = {
      Unit = {
        Description = "CamillaDSP web GUI";
        After = [ "network-online.target" "camilladsp.service" ];
        Wants = [ "network-online.target" "camilladsp.service" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.bash}/bin/bash -lc 'exec camillagui-backend -c ${config.home.homeDirectory}/.config/camillagui-backend/config.yml'";
        Restart = "on-failure";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
