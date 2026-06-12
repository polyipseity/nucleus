# hosts/MacBook/camilladsp.nix — CamillaDSP websocket service on macOS.
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
  services = args.users.${args.username}.services or { };
  userEnable = services."camilladsp".enable or true;
in
{
  config = lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
    launchd.agents."camilladsp" = {
      serviceConfig = {
        Label = "local.camilladsp";
        ProgramArguments = [
          "${pkgs.camilladsp}/bin/camilladsp"
          "-o"
          "${config.users.users.${args.username}.home}/.config/camilladsp/config.yml"
          "-p"
          "1234"
          "-w"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${
          config.users.users.${args.username}.home
        }/Library/Logs/nucleus/camilladsp/stdout.log";
        StandardErrorPath = "${
          config.users.users.${args.username}.home
        }/Library/Logs/nucleus/camilladsp/stderr.log";
      };
    };
  };
}
