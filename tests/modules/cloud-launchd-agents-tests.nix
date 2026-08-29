# tests/modules/cloud-launchd-agents-tests.nix — Cloud launchd agent generation invariant.
#
# Guards against a regression where the macOS Home Manager config silently stops
# generating the cloud mount/replica launchd agents (e.g. a stale generation that
# predates cloud-drives.nix, or a future edit that drops the launchd.agents wiring).
#
# The agents are HM-native `launchd.agents.<name>` with `domain = "user"` (installed
# to ~/Library/LaunchAgents). See .agents/instructions/launchd.instructions.md and
# .agents/instructions/cloud-drives-and-finder.instructions.md.

let
  inherit (import ../lib.nix) assert' containsRegex;

  cloudDrivesNix = builtins.readFile ../../src/modules/cloud-drives.nix;
in
{
  tests = builtins.filter (x: x != null) [
    # --- Mount agents: one launchd.agents entry per declared mount ---
    # The macOS mount block builds launchd.agents via listToAttrs with
    # name = "cloud-mount-${mount.id}" and Label = "local.cloud-mount.${mount.id}".
    (assert' (containsRegex "launchd.agents = builtins.listToAttrs" cloudDrivesNix) "cloud-drives: mounts use launchd.agents")
    (assert' (containsRegex "name = \"cloud-mount-\\$\\{mount.id\\}\"" cloudDrivesNix) "cloud-drives: mount agent name template")
    (assert' (containsRegex "Label = \"local.cloud-mount.\\$\\{mount.id\\}\"" cloudDrivesNix) "cloud-drives: mount agent Label template")
    (assert' (containsRegex "domain = \"user\"" cloudDrivesNix) "cloud-drives: domain = user")

    # --- Replica agents: one launchd.agents entry per scheduled-sync replica ---
    (assert' (containsRegex "name = \"cloud-replica-scheduled-sync-\\$\\{replica.id\\}\"" cloudDrivesNix) "cloud-drives: replica agent name template")
    (assert' (containsRegex "Label = \"local.cloud-replica-scheduled-sync.\\$\\{replica.id\\}\"" cloudDrivesNix) "cloud-drives: replica agent Label template")

    # --- macOS gating: agents only generate on darwin with declared entries ---
    # The mount block is guarded by `lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && declaredMountAgents != [ ])`
    # and the replica block by `lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && declaredScheduledSyncReplicas != [ ])`.
    (assert' (containsRegex "hostPlatform.isDarwin && declaredMountAgents != " cloudDrivesNix) "cloud-drives: mount agents gated to darwin with declared mounts")
    (assert' (containsRegex "hostPlatform.isDarwin && declaredScheduledSyncReplicas != " cloudDrivesNix) "cloud-drives: replica agents gated to darwin with declared replicas")

    # --- None of these agents may use environment.userLaunchAgents in an HM module ---
    (assert' (
      !containsRegex "environment.userLaunchAgents = builtins.listToAttrs" cloudDrivesNix
    ) "cloud-drives: not environment.userLaunchAgents")
  ];
  success = true;
  allPass = true;
}
