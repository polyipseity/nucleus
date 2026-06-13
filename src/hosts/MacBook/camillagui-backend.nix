# hosts/MacBook/camillagui-backend.nix — CamillaDSP GUI launchd service.
#
# Runs as the primary user via UserName so the daemon can access user-level
# config at $HOME/.config/camillagui-backend/. Config is deployed by Home
# Manager in modules/home.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  userHome = config.users.users.${username}.home;
in
{
  launchd.daemons."camillagui-backend" = {
    serviceConfig = {
      Label = "local.camillagui-backend";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.camillagui-backend}/bin/camillagui-backend -c $HOME/.config/camillagui-backend/config.yml"
      ];
      UserName = username;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "${userHome}/Library/Logs/nucleus/camillagui-backend/stdout.log";
      StandardErrorPath = "${userHome}/Library/Logs/nucleus/camillagui-backend/stderr.log";
    };
  };
}
