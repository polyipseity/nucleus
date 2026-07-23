# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in
# modules/home.nix.
{ pkgs, username, ... }:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  camilladspDaemon = pkgs.writeNucleusShellApplication {
    name = "camilladsp-daemon";
    runtimeInputs = [
      pkgs.camilladsp
      pkgs.websocat
      pkgs.jq
    ];
    extraEnv = {
      WS_PORT = toString wsPort;
    };
    bundleDefault = true;
  };

  camilladspHeartbeat = pkgs.writeNucleusShellApplication {
    name = "camilladsp-heartbeat";
    runtimeInputs = [
      pkgs.websocat
      pkgs.jq
    ];
    extraEnv = {
      WS_PORT = toString wsPort;
    };
    bundleDefault = true;
  };
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
      ExecStart = "${camilladspDaemon}/bin/nucleus-camilladsp-daemon";
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
      ExecStart = "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat";
    };
    wantedBy = [ "default.target" ];
  };
}
