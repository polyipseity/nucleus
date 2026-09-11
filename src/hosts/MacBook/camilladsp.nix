# hosts/MacBook/camilladsp.nix — CamillaDSP launchd services.
#
# The run service is a system daemon (launchd.daemons) that starts camilladsp
# with --no_config and never reads user-home config, so TCC is not triggered.
# Config is deployed by Home Manager in modules/home.nix.
#
# The heartbeat is a user-scoped launch agent (environment.userLaunchAgents).
# It runs inside the primary user's GUI/login session so TCC permits reading
# $HOME/.config/camilladsp/configs/config.yml (a system daemon is blocked by
# macOS TCC from reading user-home file contents — EPERM — which previously
# left the playback device null after every rebuild).
#
# Heartbeat re-pushes the config when camilladsp is not in "Running" state, so
# config re-applies when a disconnected audio device reappears.
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
      # The heartbeat probes the current default output with SwitchAudioSource;
      # without this it silently depends on the ambient PATH.
      pkgs.switchaudio-osx
    ];
  };

  envVars = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "MacBook";
  };
  resolveValue = name: envVars.resolveValue name "MacBook";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };
in
{
  launchd.daemons."camilladsp" = {
    serviceConfig = {
      Label = "local.camilladsp";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> tracks
      # making launchd services show descriptive names; do not revisit until
      # that issue is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspRun}/bin/nucleus-camilladsp-run --port ${toString wsPort}"
      ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      # Bound how fast launchd may restart this daemon. Without a throttle a
      # persistent crash loop restarts immediately and without limit.
      ThrottleInterval = 10;
      WorkingDirectory = config.users.users.${username}.home;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stderr.log";
    };
  };

  # The attribute name IS the installed filename, so it must carry the .plist
  # suffix: launchd only auto-loads plists. Naming it "camilladsp-heartbeat"
  # wrote an extension-less file that was never loaded, leaving the previously
  # loaded job running arbitrarily stale code. EnvironmentVariables must also be
  # a dict — the previous concatMap form rendered it as an <array>, which
  # launchd rejects outright.
  environment.userLaunchAgents."local.camilladsp-heartbeat.plist" = {
    enable = true;
    text = lib.generators.toPlist { escape = true; } {
      Label = "local.camilladsp-heartbeat";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${wsPort}"
      ];
      EnvironmentVariables = lib.mapAttrs (_: toString) daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      # WHY: the house default is the stdout.log/stderr.log pair for every service, so
      # per-iteration heartbeat output is kept in a rotating file rather than discarded.
      StandardOutPath = "${config.nucleus.logging.logDir}/camilladsp-heartbeat/stdout.log";
      # The heartbeat is a user-scope agent, so it logs into the user log root under its
      # own declared dir (same shape as service-watchdog-user).
      StandardErrorPath = "${config.nucleus.logging.logDir}/camilladsp-heartbeat/stderr.log";
    };
  };
}
