# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in
# modules/home.nix.
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
  # WHY the user log root and not the system one: both units below run as
  # User = username, while nixos-ensure-log-dirs creates the system log root as
  # root and log-dirs-init.sh only chowns on Darwin. A non-root service therefore
  # cannot create a file under it, and systemd treats an unopenable redirect
  # target as a start failure — not a warning. The user root is also what the
  # camilladsp preStart below already uses.
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

  systemd.services.camilladsp-heartbeat = {
    description = "CamillaDSP config heartbeat";
    after = [ "camilladsp.service" ];
    wants = [ "camilladsp.service" ];
    # systemd creates no parent directories for an append: redirect target, so the
    # directory must exist before the unit starts.
    preStart = ''
      mkdir -p '${heartbeatLogDir}'
    '';
    serviceConfig = {
      Type = "simple";
      User = username;
      Restart = "always";
      ExecStart = "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${toString wsPort}";
      StandardOutput = "append:${heartbeatLogDir}/stdout.log";
      StandardError = "append:${heartbeatLogDir}/stderr.log";
    };
    wantedBy = [ "default.target" ];
  };
}
