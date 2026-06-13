# hosts/MacBook/camilladsp.nix — CamillaDSP launchd service.
#
# Runs as the primary user via UserName so the daemon can access user-level
# config at $HOME/.config/camilladsp/. Config is deployed by Home Manager
# in modules/home.nix.
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
  camilladspDaemon = pkgs.writeShellScript "camilladsp-daemon" ''
    set -eu
    camilladsp="${pkgs.camilladsp}/bin/camilladsp"
    websocat="${pkgs.websocat}/bin/websocat"
    jq="${pkgs.jq}/bin/jq"
    ws_port="${wsPort}"
    config_file="${userHome}/.config/camilladsp/configs/config.yml"
    state_file="${userHome}/.local/state/camilladsp/statefile.yml"
    log_file="${userHome}/Library/Logs/nucleus/camilladsp/camilladsp.log"

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

    wait $pid
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
      StandardOutPath = "${userHome}/Library/Logs/nucleus/camilladsp/stdout.log";
      StandardErrorPath = "${userHome}/Library/Logs/nucleus/camilladsp/stderr.log";
    };
  };
}
