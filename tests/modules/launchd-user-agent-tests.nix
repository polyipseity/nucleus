# tests/modules/launchd-user-agent-tests.nix — launchd user-agent unification invariant.
#
# Policy (see .agents/instructions/launchd.instructions.md):
#   * Assume multi-user everywhere (never single-user).
#   * Prefer user launch agents over global agents so each user can configure
#     individually and launchd loads them without the root-domain mismatch
#     warning that global launchd.agents trigger under nix-darwin.
#
# In a Home Manager module (src/platforms/macOS/modules/default.nix) the
# user-agent mechanism is HM's native `launchd.agents.<name>` with
# `domain = "user"` (installs to ~/Library/LaunchAgents).  In the darwin
# config (camilladsp.nix, ext-discord-music-rpc.nix, cloud-drives.nix) the
# mechanism is `environment.userLaunchAgents` (nix-darwin top-level option).

let
  inherit (import ../lib.nix) assert' containsRegex;

  macosDefaultNix = builtins.readFile ../../src/platforms/macOS/modules/default.nix;
  camilladspNix = builtins.readFile ../../src/hosts/MacBook/camilladsp.nix;
  camilladspModuleNix = builtins.readFile ../../src/modules/camilladsp.nix;
  discordRpcNix = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  cloudDrivesNix = builtins.readFile ../../src/modules/cloud-drives.nix;
in
{
  tests = builtins.filter (x: x != null) [
    # --- Home Manager module (default.nix): HM-native user agents ---
    # Each primaryUser-scoped agent MUST be a launchd.agents entry with
    # domain = "user" (NOT environment.userLaunchAgents, which is invalid in
    # an HM module context).
    (assert' (containsRegex "launchd.agents.\"sccache-gc\"" macosDefaultNix) "sccache-gc: uses launchd.agents")
    (assert' (
      containsRegex "launchd.agents.\"sccache-gc\"" macosDefaultNix
      && containsRegex "domain = \"user\"" macosDefaultNix
    ) "sccache-gc: domain = user")
    (assert' (containsRegex "launchd.agents.\"log-gc-user\"" macosDefaultNix) "log-gc-user: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"betterdisplay-heartbeat\"" macosDefaultNix) "betterdisplay-heartbeat: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"ds-store-gc\"" macosDefaultNix) "ds-store-gc: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"spotlight-exclusions\"" macosDefaultNix) "spotlight-exclusions: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"nix-index-update\"" macosDefaultNix) "nix-index-update: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"icloud-exclusions\"" macosDefaultNix) "icloud-exclusions: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"service-watchdog-user\"" macosDefaultNix) "service-watchdog-user: uses launchd.agents")
    (assert' (containsRegex "launchd.agents.\"gui-env\"" macosDefaultNix) "gui-env: uses launchd.agents")
    # None of these agents may use environment.userLaunchAgents in the HM module.
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"sccache-gc\"" macosDefaultNix
    ) "sccache-gc: not environment.userLaunchAgents")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"gui-env\"" macosDefaultNix
    ) "gui-env: not environment.userLaunchAgents")

    # --- darwin config: camilladsp-heartbeat BANNED from environment.userLaunchAgents ---
    # The persistent heartbeat was migrated to HM launchd.agents (domain = "user")
    # in src/modules/camilladsp.nix because nix-darwin's environment.userLaunchAgents
    # never restarts a loaded agent on plist change (stale-process gap). The
    # darwin-only camilladsp.nix must NOT use environment.userLaunchAgents for it.
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"camilladsp-heartbeat\"" camilladspNix
    ) "camilladsp-heartbeat: banned from environment.userLaunchAgents in darwin config")
    # --- Home Manager module: camilladsp-heartbeat uses HM-native launchd.agents (domain = "user") ---
    # src/modules/camilladsp.nix is imported into the HM config (home.nix
    # sharedModules), so it must use launchd.agents.<name> with domain = "user".
    (assert' (containsRegex "launchd.agents.\"camilladsp-heartbeat\"" camilladspModuleNix) "camilladsp-heartbeat: uses launchd.agents")
    (assert' (containsRegex "domain = \"user\"" camilladspModuleNix) "camilladsp-heartbeat: domain = user")
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"camilladsp-heartbeat\"" camilladspModuleNix
    ) "camilladsp-heartbeat: not environment.userLaunchAgents")
    # --- Home Manager modules: HM-native launchd.agents with domain = "user" ---
    # ext-discord-music-rpc.nix and cloud-drives.nix are imported into the HM
    # config (home-manager.users / sharedModules), so they must use
    # launchd.agents.<name> with domain = "user", NOT environment.userLaunchAgents.
    (assert' (containsRegex "launchd.agents.\"discord-music-rpc\"" discordRpcNix) "discord-music-rpc: uses launchd.agents")
    (assert' (containsRegex "domain = \"user\"" discordRpcNix) "discord-music-rpc: domain = user")
    (assert' (containsRegex "launchd.agents = builtins.listToAttrs" cloudDrivesNix) "cloud-drives: mounts use launchd.agents")
    (assert' (containsRegex "domain = \"user\"" cloudDrivesNix) "cloud-drives: domain = user")
    # None of these agents may use environment.userLaunchAgents in HM modules.
    (assert' (
      !containsRegex "environment.userLaunchAgents.\"discord-music-rpc\"" discordRpcNix
    ) "discord-music-rpc: not environment.userLaunchAgents")
    (assert' (
      !containsRegex "environment.userLaunchAgents = builtins.listToAttrs" cloudDrivesNix
    ) "cloud-drives: not environment.userLaunchAgents")
    # Daemons must remain in launchd.daemons (not migrated)
    (assert' (containsRegex "launchd.daemons.\"camilladsp\"" camilladspNix) "camilladsp run service: still a launchd.daemons")
  ];
  success = true;
  allPass = true;
}
