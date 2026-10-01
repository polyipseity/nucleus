# hosts/MacBook/camilladsp.nix - CamillaDSP launchd services.
#
# The run service is a system daemon that never reads user-home config, so TCC
# is not triggered. The heartbeat is a user agent in the gui domain: macOS TCC
# blocks a system daemon from reading $HOME/.config/camilladsp, which left the
# playback device null after every rebuild.
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
      # Without this the probe depends on the ambient PATH.
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

  # launchd rejects a `~`-prefixed log path, so read the HM absolute value.
  heartbeatLogDir = "${
    config.home-manager.users.${username}.nucleus.logging.logDir
  }/camilladsp-heartbeat";
in
{
  launchd.daemons."camilladsp" = {
    serviceConfig = {
      Label = "local.camilladsp";
      # macOS 26+ SIP blocks unsigned store binaries for system daemons with a
      # non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed.
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> owns
      # descriptive launchd names; leave the label alone until it lands.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspRun}/bin/nucleus-camilladsp-run --port ${toString wsPort}"
      ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      # Without a throttle a crash loop restarts immediately and without limit.
      ThrottleInterval = 10;
      WorkingDirectory = config.users.users.${username}.home;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stderr.log";
    };
  };

  # nix-darwin's environment.userLaunchAgents loads a job only when it is not
  # already registered, so a plist change never restarted the KeepAlive
  # heartbeat and it ran stale code across every apply. HM boots the job out by
  # label, installs the plist, and bootstraps it into gui/<uid>.
  # ref: launchd.instructions.md -- Activation-restart gap
  #
  # The attribute name is the agent key, not a filename: HM derives the plist
  # path from the label. No /bin/sh -c wrapper, that shim is only for system
  # daemons; HM wraps gui-domain agents in its own /bin/wait4path launcher.
  home-manager.users.${username}.launchd.agents."camilladsp-heartbeat" = {
    # HM defaults this flag to false, so without it the agent is dropped and no
    # plist lands in ~/Library/LaunchAgents.
    enable = true;
    domain = "gui";
    config = {
      Label = "local.camilladsp-heartbeat";
      ProgramArguments = [
        "${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat"
        "--port"
        wsPort
      ];
      EnvironmentVariables = lib.mapAttrs (_: toString) daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      # WHY: per-iteration output goes to a rotating file, not /dev/null.
      StandardOutPath = "${heartbeatLogDir}/stdout.log";
      StandardErrorPath = "${heartbeatLogDir}/stderr.log";
    };
  };
}
