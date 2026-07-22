# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in
# modules/home.nix.
{ pkgs, username, ... }:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  camilladspDaemon = pkgs.writeShellScript "camilladsp-daemon" (
    builtins.replaceStrings
      [ "__CAMILLADSP_DAEMON_PATH__" "__CAMILLADSP_WS_PORT__" ]
      [
        (pkgs.lib.makeBinPath [
          pkgs.camilladsp
          pkgs.websocat
          pkgs.jq
        ])
        wsPort
      ]
      (
        (builtins.readFile ./../../scripts/lib/require-command-lib.sh)
        + (builtins.readFile ./../../scripts/services/camilladsp-daemon.sh)
      )
  );

  camilladspHeartbeat = pkgs.writeShellScript "camilladsp-heartbeat" (
    builtins.replaceStrings
      [ "__CAMILLADSP_HEARTBEAT_PATH__" "__CAMILLADSP_WS_PORT__" ]
      [
        (pkgs.lib.makeBinPath [
          pkgs.websocat
          pkgs.jq
        ])
        wsPort
      ]
      (
        (builtins.readFile ./../../scripts/lib/require-command-lib.sh)
        + (builtins.readFile ./../../scripts/services/camilladsp-heartbeat.sh)
      )
  );
in
{
  systemd.services.camilladsp = {
    description = "CamillaDSP audio processor with websocket API";
    after = [
      "network-online.target"
      "sound.target"
    ];
    wants = [
      "network-online.target"
      "sound.target"
    ];
    preStart = ''
      mkdir -p '%h/.local/state/nucleus/log/camilladsp' '%h/.local/state/camilladsp'
    '';
    serviceConfig = {
      Type = "simple";
      User = username;
      ExecStart = "${camilladspDaemon}";
      Restart = "always";
      WorkingDirectory = "%h";
    };
    wantedBy = [ "default.target" ];
  };

  systemd.services.camilladsp-heartbeat = {
    description = "CamillaDSP config heartbeat";
    after = [ "camilladsp.service" ];
    wants = [ "camilladsp.service" ];
    serviceConfig = {
      Type = "simple";
      User = username;
      Restart = "always";
      ExecStart = "${camilladspHeartbeat}";
    };
    wantedBy = [ "default.target" ];
  };
}
