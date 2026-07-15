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
  userHome = config.users.users.${username}.home;
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  daemonScript = ./../../scripts/camilladsp-daemon.sh;
  heartbeatScript = ./../../scripts/camilladsp-heartbeat.sh;

  camilladspDaemon = pkgs.writeShellScript "camilladsp-daemon" ''
    export PATH="${
      pkgs.lib.makeBinPath [
        pkgs.camilladsp
        pkgs.websocat
        pkgs.jq
      ]
    }:$PATH"
    exec ${daemonScript} \
      --port ${wsPort} \
      --config ${userHome}/.config/camilladsp/configs/config.yml \
      --statefile ${userHome}/.local/state/camilladsp/statefile.yml
  '';

  camilladspHeartbeat = pkgs.writeShellScript "camilladsp-heartbeat" ''
    export PATH="${
      pkgs.lib.makeBinPath [
        pkgs.websocat
        pkgs.jq
      ]
    }:$PATH"
    exec ${heartbeatScript} \
      --port ${wsPort} \
      --config ${userHome}/.config/camilladsp/configs/config.yml
  '';

  envVars = import ../../modules/lib/env-vars.nix {
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
      ProgramArguments = [ "${camilladspDaemon}" ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      ThrottleInterval = 30;
      WorkingDirectory = userHome;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/stderr.log";
    };
  };

  launchd.daemons."camilladsp-heartbeat" = {
    serviceConfig = {
      Label = "local.camilladsp-heartbeat";
      ProgramArguments = [ "${camilladspHeartbeat}" ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      StartInterval = 5;
      RunAtLoad = false;
      ThrottleInterval = 1;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/heartbeat-stderr.log";
    };
  };
}
