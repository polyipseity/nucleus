# hosts/MacBook/camilladsp.nix — CamillaDSP launchd services.
#
# Runs as the primary user via UserName so the daemon can access user-level
# config at $HOME/.config/camilladsp/. Config is deployed by Home Manager
# in modules/home.nix.
#
# Heartbeat is a separate timer-driven agent (StartInterval 5s) that
# re-pushes the config when camilladsp is not in "Running" state, so
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

  camilladspDaemon = pkgs.writeShellApplication {
    name = "camilladsp-daemon";
    runtimeInputs = [
      pkgs.camilladsp
      pkgs.websocat
      pkgs.jq
    ];
    text = ''
      exec ${../../scripts/services/camilladsp-daemon.sh} --port "${wsPort}" "$@"
    '';
  };

  camilladspHeartbeat = pkgs.writeShellApplication {
    name = "camilladsp-heartbeat";
    runtimeInputs = [
      pkgs.websocat
      pkgs.jq
    ];
    text = ''
      exec ${../../scripts/services/camilladsp-heartbeat.sh} --port "${wsPort}" "$@"
    '';
  };

  envVars = import ../../modules/lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };
  resolveValue = name: envVars.resolveValue name "macOS";
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
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> tracks
      # making launchd services show descriptive names; do not revisit until
      # that issue is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspDaemon}/bin/camilladsp-daemon"
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

  launchd.daemons."camilladsp-heartbeat" = {
    serviceConfig = {
      Label = "local.camilladsp-heartbeat";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> tracks
      # making launchd services show descriptive names; do not revisit until
      # that issue is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspHeartbeat}/bin/camilladsp-heartbeat"
      ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/heartbeat-stderr.log";
    };
  };
}
