# hosts/NixOS/camilladsp.nix — CamillaDSP daemon and config heartbeat.
#
# Both units run as the primary user so they can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in modules/home.nix.
# The daemon is a system service (User = username); the heartbeat is a systemd
# USER service, because it only pushes a per-user config file and talks to a
# loopback websocket — the same scope as the macOS launchd agent and the Windows
# per-user scheduled task. Both units capture to journald, like every other NixOS
# service (src/modules/posix/logging.nix); the stdout.log/stderr.log file pair is the
# macOS and Windows rule, not this host's.
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
    preStart = ''
      mkdir -p '%h/.local/share/nucleus/logs/camilladsp' '%h/.local/state/camilladsp'
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
  # speaks to a loopback websocket, so it needs no system-level capability. Running it
  # in the user's own manager gives it the same scope as the macOS launchd agent and the
  # Windows per-user task. Two consequences, both intentional:
  #   - it cannot order against camilladsp.service (system units are invisible to user
  #     managers), so it tolerates the daemon being absent and simply skips its tick;
  #   - it is deliberately NOT made to linger, so it starts with the user's session
  #     rather than at boot. Do not "fix" that by enabling linger.
  # WHY no StandardOutput/StandardError: NixOS services capture to journald
  # (src/modules/posix/logging.nix). The stdout.log/stderr.log file pair is the macOS and
  # Windows rule; adding file redirects here would make this the one NixOS service that
  # logs differently from every other one.
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
