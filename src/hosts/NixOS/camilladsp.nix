# hosts/NixOS/camilladsp.nix — CamillaDSP systemd service.
#
# Runs as the primary user so the daemon can access user-level config at
# ~/.config/camilladsp/. Config is deployed by Home Manager in
# modules/home.nix.
{
  config,
  pkgs,
  username,
  ...
}:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;
  userHome = config.users.users.${username}.home;

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
      mkdir -p '%h/.local/state/nucleus/log/camilladsp' '%h/.local/state/camilladsp'
    '';
    serviceConfig = {
      Type = "simple";
      User = username;
      ExecStart = "${camilladspDaemon}";
      Restart = "on-failure";
      RestartSec = 30;
      WorkingDirectory = "%h";
    };
    wantedBy = [ "default.target" ];
  };

  systemd.services.camilladsp-heartbeat = {
    description = "CamillaDSP config heartbeat";
    after = [ "camilladsp.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      ExecStart = "${camilladspHeartbeat}";
    };
  };

  systemd.timers.camilladsp-heartbeat = {
    description = "CamillaDSP heartbeat timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnUnitActiveSec = "5s";
      OnBootSec = "30s";
    };
  };
}
