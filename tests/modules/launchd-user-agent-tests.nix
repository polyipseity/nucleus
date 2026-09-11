# tests/modules/launchd-user-agent-tests.nix — launchd user-agent unification invariant.
#
# Policy (see .agents/instructions/launchd.instructions.md):
#   * Assume multi-user everywhere (never single-user).
#   * Prefer user launch agents over global agents so each user can configure
#     individually and launchd loads them without the root-domain mismatch
#     warning that global launchd.agents trigger under nix-darwin.
#
# In a Home Manager module (src/platforms/macOS/modules/*.nix) the user-agent
# mechanism is HM's native `launchd.agents.<name>` with `domain = "gui"`
# (installs to ~/Library/LaunchAgents).  The darwin config uses the same form
# where the derivation lives, through `home-manager.users.<user>.launchd.agents`
# (camilladsp.nix).  nix-darwin's `environment.userLaunchAgents` is reserved for
# short-lived jobs: it only loads a job that is not already registered, so it
# cannot restart a loaded KeepAlive agent whose plist changed.

let
  inherit (import ../lib.nix) assert' containsRegex;

  camilladspNix = builtins.readFile ../../src/hosts/MacBook/camilladsp.nix;
  discordRpcNix = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  cloudDrivesNix = builtins.readFile ../../src/modules/cloud-drives.nix;
  launchdAgentsNix = builtins.readFile ../../src/platforms/macOS/modules/launchd-agents.nix;
  servicesSchemaNix = builtins.readFile ../../src/modules/services.schema.json;

  # Every .nix file directly under src/hosts/MacBook/, concatenated, so the
  # sweep below can assert that none of them assigns
  # environment.userLaunchAgents.
  macBookHostNixSources =
    let
      dir = ../../src/hosts/MacBook;
      entries = builtins.readDir dir;
      nixFiles = builtins.filter (
        name: entries.${name} == "regular" && builtins.match ".*[.]nix" name != null
      ) (builtins.attrNames entries);
    in
    builtins.concatStringsSep "\n" (map (name: builtins.readFile (dir + "/${name}")) nixFiles);
in
{
  tests = builtins.filter (x: x != null) [
    # --- HM launchd agents (launchd-agents.nix): HM-native user agents ---
    # Each agent MUST be a launchd.agents entry with domain = "gui" (NOT
    # environment.userLaunchAgents, which is invalid in an HM module context).
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
    # None of these agents may use environment.userLaunchAgents in the HM module.
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"sccache-gc\"" launchdAgentsNix
    ) "sccache-gc: not environment.userLaunchAgents")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"gui-env\"" launchdAgentsNix
    ) "gui-env: not environment.userLaunchAgents")

    # --- darwin config: camilladsp-heartbeat is an HM gui-domain agent ---
    # The heartbeat is defined in the darwin config (its derivation lives there),
    # so it is declared through home-manager.users.<user>.launchd.agents — the
    # same HM launchd module the HM-context agents use.  A persistent KeepAlive
    # job must not use nix-darwin's environment.userLaunchAgents: that mechanism
    # only loads a job that is not already registered and therefore never
    # restarts one whose plist changed (launchd.instructions.md --
    # Activation-restart gap), which left the heartbeat running stale code.
    (assert' (containsRegex "home-manager[.]users" camilladspNix) "camilladsp-heartbeat: declared in the HM user scope")
    (assert' (containsRegex "launchd[.]agents[.]\"camilladsp-heartbeat\"" camilladspNix) "camilladsp-heartbeat: uses launchd.agents")
    (assert' (containsRegex "enable = true" camilladspNix) "camilladsp-heartbeat: enable = true set")
    (assert' (containsRegex "domain = \"gui\"" camilladspNix) "camilladsp-heartbeat: domain = gui")
    (assert' (containsRegex "Label = \"local.camilladsp-heartbeat\"" camilladspNix) "camilladsp-heartbeat: keeps the local label")
    (assert' (containsRegex "KeepAlive = true" camilladspNix) "camilladsp-heartbeat: KeepAlive = true")
    (assert' (containsRegex "RunAtLoad = true" camilladspNix) "camilladsp-heartbeat: RunAtLoad = true")
    # launchd rejects a non-dict EnvironmentVariables, so it must not be built by
    # flattening the attrset into a list.
    (assert' (
      !containsRegex "EnvironmentVariables = lib.concatMap" camilladspNix
    ) "camilladsp-heartbeat: EnvironmentVariables rendered as a dict")
    # No MacBook host module may assign environment.userLaunchAgents: persistent
    # agents there are HM launchd.agents, and the nix-darwin-option form silently
    # fails to restart a loaded job.
    (assert' (
      !containsRegex "environment[.]userLaunchAgents[.]\"" macBookHostNixSources
    ) "src/hosts/MacBook/*.nix: no environment.userLaunchAgents assignment")
    # --- Home Manager modules: HM-native launchd.agents with domain = "gui" ---
    # ext-discord-music-rpc.nix and cloud-drives.nix are imported into the HM
    # config (home-manager.users / sharedModules), so they must use
    # launchd.agents.<name> with domain = "gui", NOT environment.userLaunchAgents.
    (assert' (containsRegex "launchd.agents.\"discord-music-rpc\"" discordRpcNix) "discord-music-rpc: uses launchd.agents")
    (assert' (containsRegex "domain = \"gui\"" discordRpcNix) "discord-music-rpc: domain = gui")
    # HM's launchd module filters agents by a per-agent `enable` flag (defaults
    # false via mkEnableOption), so without `enable = true` the agent is silently
    # dropped and no plist is generated. This assertion guards against a future
    # regression that removes the flag.
    (assert' (containsRegex "enable = true" discordRpcNix) "discord-music-rpc: enable = true set")
    # All launchd agents in launchd-agents.nix must have enable = true so HM
    # generates the plist in ~/Library/LaunchAgents.
    (assert' (containsRegex "enable = true" launchdAgentsNix) "launchd-agents.nix: all agents have enable = true")
    (assert' (containsRegex "launchd.agents = builtins.listToAttrs" cloudDrivesNix) "cloud-drives: mounts use launchd.agents")
    (assert' (containsRegex "domain = \"gui\"" cloudDrivesNix) "cloud-drives: domain = gui")
    # None of these agents may use environment.userLaunchAgents in HM modules.
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"discord-music-rpc\"" discordRpcNix
    ) "discord-music-rpc: not environment.userLaunchAgents")
    (assert' (
      !containsRegex "environment.userLaunchAgents = builtins.listToAttrs" cloudDrivesNix
    ) "cloud-drives: not environment.userLaunchAgents")
    # Daemons must remain in launchd.daemons (not migrated)
    (assert' (containsRegex "launchd.daemons.\"camilladsp\"" camilladspNix) "camilladsp run service: still a launchd.daemons")

    # --- Invariant: ALL agents use domain = "gui" (not "user") ---
    # After the macOS 26 fix, every HM launchd agent MUST use domain = "gui".
    # The "user" domain causes macOS to inject LimitLoadToSessionType =
    # Background, which launchd skips during GUI login on macOS 26+.
    (assert' (
      containsRegex "domain = \"gui\"" launchdAgentsNix
      && !containsRegex "domain = \"user\"" launchdAgentsNix
    ) "launchd-agents.nix: all agents use domain = gui, none use user")
    (assert' (
      containsRegex "domain = \"gui\"" discordRpcNix && !containsRegex "domain = \"user\"" discordRpcNix
    ) "discord-music-rpc.nix: domain = gui, not user")
    (assert' (
      containsRegex "domain = \"gui\"" cloudDrivesNix && !containsRegex "domain = \"user\"" cloudDrivesNix
    ) "cloud-drives.nix: domain = gui, not user")

    # --- Invariant: no LimitLoadToSessionType = Background in agent sources ---
    # HM injects LimitLoadToSessionType = Background only for domain = "user".
    # Since all agents now use domain = "gui", none should have this injected.
    # This test guards against a regression that re-introduces the user domain.
    (assert' (
      !containsRegex "LimitLoadToSessionType = \"Background\"" launchdAgentsNix
    ) "launchd-agents.nix: no LimitLoadToSessionType = Background")
    (assert' (
      !containsRegex "LimitLoadToSessionType = \"Background\"" discordRpcNix
    ) "discord-music-rpc.nix: no LimitLoadToSessionType = Background")
    (assert' (
      !containsRegex "LimitLoadToSessionType = \"Background\"" cloudDrivesNix
    ) "cloud-drives.nix: no LimitLoadToSessionType = Background")

    # --- Schema invariant: services.schema.json uses scope, not domain ---
    # The services.json schema must use 'scope' (user/system) for service
    # classification, not 'domain' which is reserved for launchd domain.
    (assert' (
      containsRegex "\"scope\"" servicesSchemaNix && !containsRegex "\"domain\":" servicesSchemaNix
    ) "services.schema.json: uses scope, not domain in launchctlEntry")
  ];
  success = true;
  allPass = true;
}
