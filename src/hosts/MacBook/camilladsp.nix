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
  services = args.users.${config.home.username}.services or { };
  userEnable = services."camilladsp".enable or true;
in
{
  config = lib.mkIf (pkgs.stdenv.isDarwin && userEnable) {
    launchd.agents."camilladsp" = {
      enable = true;
      config = {
        Label = "local.camilladsp";
        ProgramArguments = [
          "${pkgs.camilladsp}/bin/camilladsp"
          "-o"
          "${config.home.homeDirectory}/.config/camilladsp/config.yml"
          "-p"
          "1234"
          "-w"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.nucleus.logging.logDir}/camilladsp/stdout.log";
        StandardErrorPath = "${config.nucleus.logging.logDir}/camilladsp/stderr.log";
      };
    };
  };
}
