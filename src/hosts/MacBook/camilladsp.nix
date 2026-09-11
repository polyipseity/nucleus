# hosts/MacBook/camilladsp.nix — CamillaDSP launchd services.
#
# The run service is a system daemon (launchd.daemons) that starts camilladsp
# with --no_config and never reads user-home config, so TCC is not triggered.
# Config is deployed by Home Manager in modules/home.nix.
#
# The heartbeat is a user-scoped launch agent (HM launchd.agents, domain = "gui").
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

  # launchd.agents validates StandardOutPath/StandardErrorPath as absolute paths.
  # The darwin-level logDir is the `~`-prefixed registry default, so read the
  # HM-side absolute value instead — the same one the sibling HM launchd agents
  # use (home.nix derives it from home.homeDirectory).
  heartbeatLogDir = "${
    config.home-manager.users.${username}.nucleus.logging.logDir
  }/camilladsp-heartbeat";
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

  # A persistent user-scoped job must be an HM launchd agent, not nix-darwin's
  # environment.userLaunchAgents: that mechanism only loads a job when it is not
  # already registered, so a plist change never restarts a loaded KeepAlive job
  # and the heartbeat kept running stale code across every apply.  HM boots the
  # job out by label, installs the plist and bootstraps it into gui/<uid>, which
  # converges on the next apply.
  # ref: launchd.instructions.md -- Activation-restart gap
  #
  # The attribute name is the agent key, not a filename: HM derives the plist
  # path from the label.  No /bin/sh -c wrapper here — that shim exists only for
  # system daemons, where macOS 26+ SIP blocks unsigned store binaries; HM wraps
  # gui-domain agents in its own /bin/wait4path launcher instead.
  home-manager.users.${username}.launchd.agents."camilladsp-heartbeat" = {
    # HM's launchd module filters agents by a per-agent `enable` flag (defaults
    # false via mkEnableOption), so without this the agent is silently dropped
    # and no plist is generated in ~/Library/LaunchAgents.
    enable = true;
    domain = "gui";
    config = {
      Label = "local.camilladsp-heartbeat";
      # Heartbeat re-pushes the config when camilladsp is not in "Running" state.
      ProgramArguments = [
        "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat"
        "--port"
        wsPort
      ];
      EnvironmentVariables = lib.mapAttrs (_: toString) daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      # WHY: the house default is the stdout.log/stderr.log pair for every service, so
      # per-iteration heartbeat output is kept in a rotating file rather than discarded.
      StandardOutPath = "${heartbeatLogDir}/stdout.log";
      # The heartbeat is a user-scope agent, so it logs into the user log root under its
      # own declared dir (same shape as service-watchdog-user).
      StandardErrorPath = "${heartbeatLogDir}/stderr.log";
    };
  };
}
