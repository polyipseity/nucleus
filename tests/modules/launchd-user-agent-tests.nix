# tests/modules/launchd-user-agent-tests.nix — launchd user-agent unification invariant.

let
  inherit (import ../lib.nix) assert' containsRegex;

  macosDefaultNix = builtins.readFile ../../src/platforms/macOS/modules/default.nix;
  camilladspNix = builtins.readFile ../../src/hosts/MacBook/camilladsp.nix;
  discordRpcNix = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  cloudDrivesNix = builtins.readFile ../../src/modules/cloud-drives.nix;
in
{
  tests = builtins.filter (x: x != null) [
    # Each known primaryUser-scoped agent MUST be defined via environment.userLaunchAgents
    (assert' (containsRegex "environment.userLaunchAgents.\"sccache-gc\"" macosDefaultNix) "sccache-gc: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"log-gc-user\"" macosDefaultNix) "log-gc-user: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"betterdisplay-heartbeat\"" macosDefaultNix) "betterdisplay-heartbeat: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"ds-store-gc\"" macosDefaultNix) "ds-store-gc: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"spotlight-exclusions\"" macosDefaultNix) "spotlight-exclusions: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"nix-index-update\"" macosDefaultNix) "nix-index-update: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"icloud-exclusions\"" macosDefaultNix) "icloud-exclusions: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"service-watchdog-user\"" macosDefaultNix) "service-watchdog-user: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"gui-env\"" macosDefaultNix) "gui-env: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"camilladsp-heartbeat\"" camilladspNix) "camilladsp-heartbeat: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents.\"discord-music-rpc\"" discordRpcNix) "discord-music-rpc: uses environment.userLaunchAgents")
    (assert' (containsRegex "environment.userLaunchAgents = builtins.listToAttrs" cloudDrivesNix) "cloud-drives: mounts use environment.userLaunchAgents")
    # None of these agents may remain in launchd.agents (global agents)
    (assert' (
      !containsRegex "launchd.agents.\"sccache-gc\"" macosDefaultNix
    ) "sccache-gc: not in launchd.agents")
    (assert' (
      !containsRegex "launchd.agents.\"camilladsp-heartbeat\"" camilladspNix
    ) "camilladsp-heartbeat: not in launchd.agents")
    (assert' (
      !containsRegex "launchd.agents.\"discord-music-rpc\"" discordRpcNix
    ) "discord-music-rpc: not in launchd.agents")
    (assert' (
      !containsRegex "launchd.agents = builtins.listToAttrs" cloudDrivesNix
    ) "cloud-drives: not in launchd.agents")
    # Daemons must remain in launchd.daemons (not migrated)
    (assert' (containsRegex "launchd.daemons.\"camilladsp\"" camilladspNix) "camilladsp run service: still a launchd.daemons")
  ];
  success = true;
  allPass = true;
}
