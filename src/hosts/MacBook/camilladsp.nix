# hosts/MacBook/camilladsp.nix — CamillaDSP launchd service.
#
# Runs as the primary user via UserName so the daemon can access user-level
# config at $HOME/.config/camilladsp/. Config is deployed by Home Manager
# in modules/home.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  userHome = config.users.users.${username}.home;
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;
in
{
  launchd.daemons."camilladsp" = {
    serviceConfig = {
      Label = "local.camilladsp";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.camilladsp}/bin/camilladsp -o $HOME/.config/camilladsp/config.yml -p ${wsPort} -w"
      ];
      UserName = username;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "${userHome}/Library/Logs/nucleus/camilladsp/stdout.log";
      StandardErrorPath = "${userHome}/Library/Logs/nucleus/camilladsp/stderr.log";
    };
  };
}
