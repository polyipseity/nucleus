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
in
{
  launchd.daemons."camilladsp" = {
    serviceConfig = {
      Label = "local.camilladsp";
      ProgramArguments = [ "${camilladspDaemon}" ];
      UserName = username;
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
      StartInterval = 5;
      RunAtLoad = false;
      ThrottleInterval = 1;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/heartbeat-stderr.log";
    };
  };
}
