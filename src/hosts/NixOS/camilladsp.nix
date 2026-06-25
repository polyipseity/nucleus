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
  camilladspDaemon = pkgs.writeShellScript "camilladsp-daemon" ''
    set -eu
    camilladsp="${pkgs.camilladsp}/bin/camilladsp"
    websocat="${pkgs.websocat}/bin/websocat"
    jq="${pkgs.jq}/bin/jq"
    ws_port="${wsPort}"
    config_file="${userHome}/.config/camilladsp/configs/config.yml"
    state_file="${userHome}/.local/state/camilladsp/statefile.yml"
    log_file="${userHome}/.local/state/nucleus/log/camilladsp/camilladsp.log"

    mkdir -p "$(dirname "$state_file")"

    "$camilladsp" -p "$ws_port" --statefile "$state_file" -w --no_config -o "$log_file" &
    pid=$!

    for i in $(seq 1 60); do
      if [ -f "$config_file" ] && \
         "$jq" -cRs '{SetConfig: .}' "$config_file" | \
         "$websocat" -1 "ws://127.0.0.1:$ws_port" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done

    # Heartbeat: re-push config every 5s so config re-applies when a
    # disconnected audio device reappears.
    while sleep 5; do
      "$jq" -cRs '{SetConfig: .}' "$config_file" | \
        "$websocat" -1 "ws://127.0.0.1:$ws_port" >/dev/null 2>&1 || true
    done &
    heartbeat_pid=$!

    wait $pid
    kill "$heartbeat_pid" 2>/dev/null
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
}
