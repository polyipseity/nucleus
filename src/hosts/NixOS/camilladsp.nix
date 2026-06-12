# hosts/NixOS/camilladsp.nix — CamillaDSP websocket service on NixOS.
#
# Runs the CamillaDSP audio processor with its websocket API on port 1234
# for camillagui-backend control.
args@{
  config,
  lib,
  pkgs,
  ...
}:

let
  services = args.users.${config.home.username}.services or { };
  userEnable = services."camilladsp".enable or true;
in
{
  config = lib.mkIf (pkgs.stdenv.isLinux && userEnable) {
    systemd.user.services."camilladsp" = {
      Unit = {
        Description = "CamillaDSP audio processor with websocket API";
        After = [ "network-online.target" "sound.target" ];
        Wants = [ "network-online.target" "sound.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.camilladsp}/bin/camilladsp -o ${config.home.homeDirectory}/.config/camilladsp/config.yml -p 1234 -w";
        Restart = "on-failure";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
