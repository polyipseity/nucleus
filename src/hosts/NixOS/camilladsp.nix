# hosts/NixOS/camilladsp.nix — CamillaDSP daemon and config heartbeat.
#
# Both units run as the primary user so they can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in modules/home.nix.
# The daemon is a system service (User = username); the heartbeat is a systemd
# USER service, because it only pushes a per-user config file and talks to a
# loopback websocket — the same scope as the macOS launchd agent and the Windows
# per-user scheduled task.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  # config.nucleus.logging.logDir is a `~/...` template, and systemd does not
  # expand `~`; resolve it against the service user's home instead.
  # WHY the user log root and not the system one: nixos-ensure-log-dirs creates the
  # system log root as root and log-dirs-init.sh only chowns on Darwin, so a non-root
  # service cannot create a file under it, and systemd treats an unopenable redirect
  # target as a start failure rather than a warning. The user root is also where the
  # daemon's own preStart already writes.
  heartbeatLogDir = "${
    lib.replaceStrings [ "~" ] [ config.users.users.${username}.home ] config.nucleus.logging.logDir
  }/camilladsp-heartbeat";

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
  systemd.user.services.camilladsp-heartbeat = {
    description = "CamillaDSP config heartbeat";
    # systemd creates no parent directories for an append: redirect target, so the
    # directory must exist before the unit starts.
    preStart = ''
      mkdir -p '${heartbeatLogDir}'
    '';
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${toString wsPort}";
      StandardOutput = "append:${heartbeatLogDir}/stdout.log";
      StandardError = "append:${heartbeatLogDir}/stderr.log";
    };
    wantedBy = [ "default.target" ];
  };
}
