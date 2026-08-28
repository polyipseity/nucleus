# hosts/MacBook/camilladsp.nix — CamillaDSP launchd services.
#
# The run service is a system daemon (launchd.daemons) that starts camilladsp
# with --no_config and never reads user-home config, so TCC is not triggered.
# Config is deployed by Home Manager in modules/home.nix.
#
# The heartbeat is a user launch agent (HM launchd.agents, domain = "user") in
# src/modules/camilladsp.nix. It runs inside the primary user's GUI/login
# session so TCC permits reading $HOME/.config/camilladsp/configs/config.yml
# (a system daemon is blocked by TCC from reading user-home file contents —
# EPERM — which previously left the playback device null after every rebuild).
# HM's setupLaunchAgents restarts the agent on plist change, so a rebuild takes
# effect on the next apply. Trade-off: the agent only runs while the user is
# logged into a GUI session (not at the login window); acceptable for audio.
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

  envVars = import ../../modules/lib/env-catalog.nix {
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
      WorkingDirectory = config.users.users.${username}.home;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stderr.log";
    };
  };
}
