# tests/modules/launchd-agents-tests.nix — launchd agent domain and cloud drive invariant.
#
# Validates that all HM launchd agents use domain = "gui" (not "user") and
# that cloud drive mount/replica agents are properly generated.
#
# Run with: nix-instantiate --eval tests/modules/launchd-agents-tests.nix

let
  inherit (import ../lib.nix) assert' containsRegex;

  camilladspNix = builtins.readFile ../../src/hosts/MacBook/camilladsp.nix;
  discordRpcNix = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  launchdAgentsNix = builtins.readFile ../../src/platforms/macOS/modules/launchd-agents.nix;
  servicesSchemaNix = builtins.readFile ../../src/modules/services.schema.json;
  cloudDrivesNix = builtins.readFile ../../src/modules/cloud-drives.nix;

  # Check that no MacBook host module uses environment.userLaunchAgents.
  # Read files individually to avoid concatenating ~106KB into one string
  # (causes stack overflow on CI when regex matching).
  macBookHostFiles =
    let
      dir = ../../src/hosts/MacBook;
      entries = builtins.readDir dir;
    in
    map (name: builtins.readFile (dir + "/${name}")) (
      builtins.filter (
        name: entries.${name} == "regular" && builtins.match ".*[.]nix" name != null
      ) (builtins.attrNames entries)
    );
  macBookHasUserLaunchAgents = builtins.any (
    content: containsRegex "environment[.]userLaunchAgents[.]\"" content
  ) macBookHostFiles;
in
{
  tests = builtins.filter (x: x != null) [
    # --- HM launchd agents: domain = "gui" ---
    (assert' (containsRegex "launchd.agents.\"sccache-gc\"" launchdAgentsNix) "sccache-gc: uses launchd.agents")
    (assert' (
      containsRegex "launchd.agents.\"sccache-gc\"" launchdAgentsNix
      && containsRegex "domain = \"gui\"" launchdAgentsNix
    ) "sccache-gc: domain = gui")
    (assert' (containsRegex "launchd.agents.\"log-gc-user\"" launchdAgentsNix) "log-gc-user: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"betterdisplay-heartbeat\"" launchdAgentsNix) "betterdisplay-heartbeat: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"ds-store-gc\"" launchdAgentsNix) "ds-store-gc: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"spotlight-exclusions\"" launchdAgentsNix) "spotlight-exclusions: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"nix-index-update\"" launchdAgentsNix) "nix-index-update: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"icloud-exclusions\"" launchdAgentsNix) "icloud-exclusions: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"service-watchdog-user\"" launchdAgentsNix) "service-watchdog-user: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"gui-env\"" launchdAgentsNix) "gui-env: uses launchd.agents")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"sccache-gc\"" launchdAgentsNix
    ) "sccache-gc: not environment.userLaunchAgents")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"gui-env\"" launchdAgentsNix
    ) "gui-env: not environment.userLaunchAgents")

    # --- camilladsp-heartbeat: HM gui-domain agent ---
    (assert' (containsRegex "home-manager[.]users" camilladspNix) "camilladsp-heartbeat: HM user scope")
    (assert' (containsRegex "launchd[.]agents[.]\"camilladsp-heartbeat\"" camilladspNix) "camilladsp-heartbeat: uses launchd.agents")
    (assert' (containsRegex "enable = true" camilladspNix) "camilladsp-heartbeat: enable = true")
    (assert' (containsRegex "domain = \"gui\"" camilladspNix) "camilladsp-heartbeat: domain = gui")
    (assert' (containsRegex "Label = \"local.camilladsp-heartbeat\"" camilladspNix) "camilladsp-heartbeat: local label")
    (assert' (containsRegex "KeepAlive = true" camilladspNix) "camilladsp-heartbeat: KeepAlive = true")
    (assert' (containsRegex "RunAtLoad = true" camilladspNix) "camilladsp-heartbeat: RunAtLoad = true")
    (assert' (
      !containsRegex "EnvironmentVariables = lib.concatMap" camilladspNix
    ) "camilladsp-heartbeat: EnvironmentVariables as dict")
    (assert' (
      !macBookHasUserLaunchAgents
    ) "MacBook host modules: no environment.userLaunchAgents")

    # --- discord-music-rpc: HM launchd.agents with domain = "gui" ---
    (assert' (containsRegex "launchd.agents.\"discord-music-rpc\"" discordRpcNix) "discord-music-rpc: uses launchd.agents")
    (assert' (containsRegex "domain = \"gui\"" discordRpcNix) "discord-music-rpc: domain = gui")
    (assert' (containsRegex "enable = true" discordRpcNix) "discord-music-rpc: enable = true")
    (assert' (containsRegex "enable = true" launchdAgentsNix) "launchd-agents.nix: all agents have enable = true")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"discord-music-rpc\"" discordRpcNix
    ) "discord-music-rpc: not environment.userLaunchAgents")
    (assert' (containsRegex "launchd.daemons.\"camilladsp\"" camilladspNix) "camilladsp run service: still launchd.daemons")

    # --- Invariant: all agents use domain = "gui" ---
    (assert' (
      containsRegex "domain = \"gui\"" launchdAgentsNix
      && !containsRegex "domain = \"user\"" launchdAgentsNix
    ) "launchd-agents.nix: all agents domain = gui")
    (assert' (
      containsRegex "domain = \"gui\"" discordRpcNix && !containsRegex "domain = \"user\"" discordRpcNix
    ) "discord-music-rpc.nix: domain = gui")

    # --- Invariant: no LimitLoadToSessionType = Background ---
    (assert' (
      !containsRegex "LimitLoadToSessionType = \"Background\"" launchdAgentsNix
    ) "launchd-agents.nix: no LimitLoadToSessionType = Background")
    (assert' (
      !containsRegex "LimitLoadToSessionType = \"Background\"" discordRpcNix
    ) "discord-music-rpc.nix: no LimitLoadToSessionType = Background")

    # --- Schema: services.schema.json uses scope, not domain ---
    (assert' (
      containsRegex "\"scope\"" servicesSchemaNix && !containsRegex "\"domain\":" servicesSchemaNix
    ) "services.schema.json: uses scope, not domain")

    # --- Cloud drives: mount agents ---
    (assert' (containsRegex "launchd.agents = builtins.listToAttrs" cloudDrivesNix) "cloud-drives: mounts use launchd.agents")
    (assert' (containsRegex "name = \"cloud-mount-\\$\\{mount.id\\}\"" cloudDrivesNix) "cloud-drives: mount agent name template")
    (assert' (containsRegex "Label = \"local.cloud-mount.\\$\\{mount.id\\}\"" cloudDrivesNix) "cloud-drives: mount Label template")
    (assert' (containsRegex "domain = \"gui\"" cloudDrivesNix) "cloud-drives: domain = gui")
    (assert' (containsRegex "domain = .gui.;.*enable = true" cloudDrivesNix) "cloud-drives: enable = true in value blocks")

    # --- Cloud drives: replica agents ---
    (assert' (containsRegex "name = \"cloud-replica-scheduled-sync-\\$\\{replica.id\\}\"" cloudDrivesNix) "cloud-drives: replica agent name template")
    (assert' (containsRegex "Label = \"local.cloud-replica-scheduled-sync.\\$\\{replica.id\\}\"" cloudDrivesNix) "cloud-drives: replica Label template")

    # --- Cloud drives: darwin gating ---
    (assert' (containsRegex "hostPlatform.isDarwin && declaredMountAgents != " cloudDrivesNix) "cloud-drives: mount agents gated to darwin")
    (assert' (containsRegex "hostPlatform.isDarwin && declaredScheduledSyncReplicas != " cloudDrivesNix) "cloud-drives: replica agents gated to darwin")

    # --- Cloud drives: not environment.userLaunchAgents ---
    (assert' (
      !containsRegex "environment.userLaunchAgents = builtins.listToAttrs" cloudDrivesNix
    ) "cloud-drives: not environment.userLaunchAgents")
  ];

  success = true;
  message = "Launchd agents tests passed";
}
