# hosts/NixOS/camilladsp.nix - CamillaDSP daemon and config heartbeat. Both run
# as the primary user to reach ~/.config/camilladsp/, which Home Manager deploys
# via modules/home.nix. The daemon is a system service, the heartbeat a systemd
# USER service. Both log to journald like every other NixOS service.
{
  pkgs,
  username,
  ...
}:

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
      (pkgs.python3.withPackages (p: [ p.pyyaml ]))
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
    # Only the state dir: the daemon logs to journald, so there is no
    # file capture target to create.
    preStart = ''
      mkdir -p '%h/.local/state/camilladsp'
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

  # WHY a systemd USER service: the heartbeat only pushes a per-user config file and
  # speaks to a loopback websocket, so it needs no system-level capability, which
  # matches the macOS launchd agent and the Windows per-user task scope. Two
  # consequences, both intentional: it cannot order against camilladsp.service
  # (system units are invisible to user managers) so it skips its tick when the
  # daemon is absent, and it is deliberately NOT set to linger, so it starts with
  # the session rather than at boot. Do not enable linger.
  # WHY no StandardOutput/StandardError: NixOS services log to journald
  # (src/modules/posix/logging.nix); file pairs are the macOS and Windows rule.
  systemd.user.services.camilladsp-heartbeat = {
    description = "CamillaDSP config heartbeat";
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${toString wsPort}";
    };
    wantedBy = [ "default.target" ];
  };
}
