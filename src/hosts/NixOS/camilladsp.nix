# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in
# modules/home.nix.
{ pkgs, username, ... }:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  camilladspRun = pkgs.writeNucleusShellApplication {
    name = "camilladsp-run";
    scriptName = "src/scripts/services/camilladsp-run";
    runtimeInputs = [
      pkgs.camilladsp
    ];
  };

  camilladspHeartbeat = pkgs.writeNucleusShellApplication {
    name = "camilladsp-heartbeat";
    scriptName = "src/scripts/services/camilladsp-heartbeat";
    runtimeInputs = [
      pkgs.websocat
      pkgs.jq
      pkgs.python3.withPackages
      (p: [ p.pyyaml ])
    ];
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
      ExecStart = "${camilladspRun}/bin/nucleus-camilladsp-run --port ${toString wsPort}";
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
      ExecStart = "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${toString wsPort}";
    };
    wantedBy = [ "default.target" ];
  };
}
