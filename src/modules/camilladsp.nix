# CamillaDSP user-scope heartbeat launchd agent (macOS).
#
# The heartbeat re-pushes the CamillaDSP config when the system default output
# device changes or when camilladsp is not in the "Running" state. It runs as a
# user launch agent so it inherits the session's TCC grants and can read
# $HOME/.config/camilladsp/configs/config.yml (a system daemon is blocked by
# macOS TCC from reading user-home file contents — EPERM — which previously
# left the playback device null after every rebuild).
#
# Mechanism: HM-native launchd.agents with domain = "user" (installs to
# ~/Library/LaunchAgents, runs in the user's gui/<uid> domain). This is the
# correct user-scoped mechanism — Home Manager's setupLaunchAgents restarts the
# agent on any plist change (cmp -s), so a store-hash change after a rebuild
# takes effect on the next apply without manual intervention.
#
# Do NOT use environment.userLaunchAgents (nix-darwin top-level option) for
# this job: nix-darwin only launchctl-loads a userLaunchAgent if it is NOT
# already loaded, so a loaded agent is never restarted when its plist (store
# hash) changes — the stale binary keeps running across every apply. That gap
# is why camilladsp-heartbeat was migrated here from hosts/MacBook/camilladsp.nix.
#
# The run service (camilladsp) stays a system launchd.daemon in
# hosts/MacBook/camilladsp.nix because it must start with no user logged in and
# never reads user-home config (so TCC is not triggered).
{
  config,
  lib,
  pkgs,
  username,
  hostName,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
  wsPort = toString servicesJSON.camilladsp.network.websocket.port;

  camilladspHeartbeat = pkgs.writeNucleusShellApplication {
    name = "camilladsp-heartbeat";
    scriptName = "src/scripts/services/camilladsp-heartbeat";
    runtimeInputs = [
      pkgs.websocat
      pkgs.jq
      (pkgs.python3.withPackages (p: [ p.pyyaml ]))
    ];
  };

  envVars = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };
  resolveValue = name: envVars.resolveValue name "MacBook";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  launchd.agents."camilladsp-heartbeat" = {
    domain = "user";
    # HM's launchd module filters agents by a per-agent `enable` flag (defaults
    # false via mkEnableOption), so without this the agent is silently dropped
    # and no plist is generated in ~/Library/LaunchAgents.
    enable = true;
    config = {
      Label = "local.camilladsp-heartbeat";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${camilladspHeartbeat}/bin/nucleus-camilladsp-heartbeat --port ${wsPort}"
      ];
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camilladsp/heartbeat-stderr.log";
    };
  };
}
