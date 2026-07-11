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
    # Checks config.json on each iteration so dynamic changes apply instantly.
    config_json="${userHome}/.local/state/nucleus/config.json"
    backoff=5
    while true; do
      sleep "$backoff"
      _hb_enabled=true
      if [ -f "$config_json" ]; then
        _val=$("$jq" -r '.camilladsp.heartbeat // true' "$config_json")
        [ "$_val" = "false" ] && _hb_enabled=false
      fi
      [ "$_hb_enabled" = "false" ] && continue

      # Only push config when not already running, to avoid filling
      # CamillaDSP's bounded command channel (capacity 10).
      _state_resp=$(echo '{"GetState":null}' | "$websocat" -1 "ws://127.0.0.1:$ws_port" 2>/dev/null)
      _state=$(echo "$_state_resp" | "$jq" -r '.GetState.value // empty')
      if [ "$_state" = "Running" ]; then
        backoff=5
        continue
      fi

      # Push config; on failure (device timeout, rate limit), back off.
      _push_resp=$(echo '{"SetConfig":'"$("$jq" -cRs '.' "$config_file")"'}' | "$websocat" -1 "ws://127.0.0.1:$ws_port" 2>/dev/null)
      if echo "$_push_resp" | "$jq" -e '.SetConfig.result == "Ok"' >/dev/null 2>&1; then
        backoff=5
      else
        backoff=$((backoff * 2))
        [ "$backoff" -gt 60 ] && backoff=60
      fi
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
