# tests/modules/harness-bridge-tests.nix: harness bridge wiring and default parity.
#
# Hook JSON files call nucleus-utils subcommands (harness-filter, harness-drive)
# by bare PATH name, so one shared hook definition drives every platform. The
# implementations stay in src/scripts/notify/ and are dispatched by
# scripts/utils.sh/.ps1.
#
# Failures this test makes loud:
#   1. a hook that names a command/shape no platform deploys: silent no-op;
#   2. hook timeout budget drifting from the approval wait window;
#   3. harness bridge command deployment regressing into ~/.local/bin internals.
#
# Run with: nix-instantiate --eval --strict tests/modules/harness-bridge-tests.nix

let
  inherit (import ../lib.nix) all assert';
  root = ../..;
  read = path: builtins.readFile (root + path);
  flatten = builtins.replaceStrings [ "\n" "\r" "\t" ] [ " " " " " " ];

  # Implementation scripts remain the source of truth for harness bridge logic.
  harnessImpls = [
    "harness-approval"
    "harness-drive"
    "harness-filter"
    "harness-notify"
  ];

  guardPolicy = "/src/scripts/notify/filters/safe-delete.ts";
  flatAgentsNix = flatten (read "/src/modules/agents.nix");
  flatShellDefaultNix = flatten (read "/src/modules/shell/default.nix");
  flatSyncNucleusAppShim = flatten (
    read "/src/platforms/Windows/modules/user/Sync-NucleusAppShim.ps1"
  );

  copilotHooks =
    (builtins.fromJSON (read "/src/users/default/agents/hooks/harness-notify.json")).hooks;
  cursorHooks = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).hooks;
  cursorVersion = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).version;

  # Claude nests command entries one level deeper than the other two files.
  claudeHooks = (builtins.fromJSON (read "/src/users/default/claude/settings.json")).hooks;
  claudeEntries = builtins.concatMap (groups: builtins.concatMap (group: group.hooks) groups) (
    builtins.attrValues claudeHooks
  );
  claudeBashPreToolUseEntries = builtins.concatMap (group: group.hooks) (
    builtins.filter (group: group.matcher == "Bash") claudeHooks.PreToolUse
  );

  allEntries = builtins.concatLists (
    builtins.attrValues copilotHooks ++ builtins.attrValues cursorHooks
  );

  # WHY: text reads, not behavior. The hook budget has no runtime surface to test
  # against; the ceiling is declared here and compared against every filter entry.
  hookCeiling = 3600;
  flatConfigSh = flatten (read "/scripts/config.sh");
  flatConfigPs1 = flatten (read "/scripts/config.ps1");
  flatApprovalScript = flatten (read "/src/scripts/notify/harness-approval.sh");
  flatApprovalScriptPs1 = flatten (read "/src/scripts/notify/harness-approval.ps1");

  # First token of a hook command (PATH-resolved executable).
  entryPointOf =
    command:
    builtins.head (builtins.filter (x: builtins.isString x && x != "") (builtins.split " " command));
  entriesWithCommand = entries: command: builtins.filter (entry: entry.command == command) entries;

  # Filter/drive hooks are now invoked as: nucleus-utils harness-filter <harness>
  # and nucleus-utils harness-drive <harness>.
  isUtilsSubcommand =
    subcommand: command: builtins.match "nucleus-utils ${subcommand}( [a-z0-9_-]+)?" command != null;
  filterEntries = builtins.filter (entry: isUtilsSubcommand "harness-filter" entry.command) (
    allEntries ++ claudeEntries
  );
in
{
  tests = builtins.filter (x: x != null) [
    # --- Implementation scripts exist for both platforms ---
    (assert' (all (
      name: builtins.pathExists (root + "/src/scripts/notify/${name}.sh")
    ) harnessImpls) "every harness bridge implementation needs a POSIX script in src/scripts/notify/")
    (assert' (all (
      name: builtins.pathExists (root + "/src/scripts/notify/${name}.ps1")
    ) harnessImpls) "every harness bridge implementation needs a Windows script in src/scripts/notify/")

    # --- Hooks resolve nucleus-utils by bare PATH name ---
    (assert' (all (entry: entryPointOf entry.command == "nucleus-utils") (
      allEntries ++ claudeEntries
    )) "every hook command must invoke nucleus-utils by bare PATH name")
    (assert'
      (all (entry: builtins.match "nucleus-utils( [a-z0-9_-]+)+" entry.command != null) (
        allEntries ++ claudeEntries
      ))
      "hook commands must be bare PATH-resolved nucleus-utils subcommands; no absolute path, home expansion, or environment reference"
    )

    # --- Shared deletion-guard policy remains the single source ---
    (assert' (builtins.pathExists (
      root + guardPolicy
    )) "the safe-delete policy file must exist as the shared implementation/filter source")

    # --- POSIX/Windows command-surface deployment (no internal ~/.local/bin harness executables) ---
    (assert' (
      builtins.match ".*home[.]file[.]\"\\.local/bin/harness-notify\".*" flatAgentsNix == null
    ) "agents.nix must not deploy a harness-notify ~/.local/bin entry; hooks use nucleus-utils")
    (assert' (
      builtins.match ".*home[.]file[.]\"\\.local/bin/harness-approval\".*" flatAgentsNix == null
    ) "agents.nix must not deploy a harness-approval ~/.local/bin entry; hooks use nucleus-utils")
    (assert' (
      builtins.match ".*home[.]file[.]\"\\.local/bin/harness-filter\".*" flatAgentsNix == null
    ) "agents.nix must not deploy a harness-filter ~/.local/bin entry; hooks use nucleus-utils")
    (assert' (
      builtins.match ".*home[.]file[.]\"\\.local/bin/harness-drive\".*" flatAgentsNix == null
    ) "agents.nix must not deploy a harness-drive ~/.local/bin entry; hooks use nucleus-utils")
    (assert'
      (builtins.match ".*home[.]file[.]\"\\.local/bin/safe-delete-guard\".*" flatShellDefaultNix == null)
      "shell/default.nix must not deploy a safe-delete-guard ~/.local/bin entry; invoke via nucleus-utils"
    )
    (assert' (
      builtins.match ".*home[.]file[.]\"\\.local/bin/harness-.*" (
        flatAgentsNix + " " + flatShellDefaultNix
      ) == null
    ) "agents.nix and shell/default.nix must not deploy any harness-* ~/.local/bin executable")
    (assert' (
      builtins.match ".*nucleus-apps[.]json.*" flatSyncNucleusAppShim != null
    ) "Sync-NucleusAppShim must derive Windows nucleus-* shims from nucleus-apps.json")

    # --- Timeout budget covers the approval wait ---
    (assert' (all (entry: entry ? timeout) allEntries) "every hook entry must declare a timeout")
    (assert' (filterEntries != [ ])
      "the hook files must run the filter runner via nucleus-utils at least once, or the approval budget below is vacuous"
    )
    (assert' (all (entry: entry.timeout == hookCeiling) filterEntries)
      "a filter entry's timeout must be the hook ceiling (${toString hookCeiling} s); the approval sources wait until answered by default, so a shorter hook timeout turns a human's answer into a harness denial"
    )

    # --- Claude carries the same budget ---
    (assert' (builtins.length claudeEntries > 0)
      "the Claude hook config must declare at least one hook entry; an emptied hook set would make the timeout asserts below vacuous"
    )
    (assert'
      (
        builtins.length (
          entriesWithCommand claudeBashPreToolUseEntries "nucleus-utils harness-filter claude"
        ) == 1
      )
      "Claude's Bash PreToolUse must run exactly the filter runner via nucleus-utils: one entry point makes the decision, so no second hook can answer a deletion differently"
    )
    (assert' (all (entry: entry ? timeout) claudeEntries)
      "every Claude hook entry must declare a timeout, or the harness applies a budget of its own and the filter can be killed before the approval window"
    )

    # --- Copilot wiring ---
    (assert' (
      builtins.length copilotHooks.PreToolUse == 1
      &&
        builtins.length (entriesWithCommand copilotHooks.PreToolUse "nucleus-utils harness-filter copilot")
        == 1
    ) "VS Code Copilot PreToolUse must run exactly the filter runner via nucleus-utils")
    (assert' (all (
      entry: entry.type == "command"
    ) copilotHooks.PreToolUse) "VS Code Copilot PreToolUse hooks must all be command hooks")
    (assert' (
      builtins.length copilotHooks.Stop == 1
    ) "VS Code Copilot must drive turn ends with exactly one Stop hook")
    (assert' ((builtins.head copilotHooks.Stop).command == "nucleus-utils harness-drive copilot")
      "VS Code Copilot Stop must run harness-drive via nucleus-utils, which notifies and injects a queued prompt"
    )

    # --- Cursor wiring ---
    (assert' (cursorVersion == 1) "Cursor hook definitions must use config version 1")
    (assert' (
      builtins.length cursorHooks.beforeShellExecution == 1
      &&
        builtins.length (
          entriesWithCommand cursorHooks.beforeShellExecution "nucleus-utils harness-filter cursor"
        ) == 1
    ) "Cursor shell executions must run exactly the filter runner via nucleus-utils")
    (assert' (
      builtins.length cursorHooks.beforeMCPExecution == 1
      && (builtins.head cursorHooks.beforeMCPExecution).command == "nucleus-utils harness-filter cursor"
    ) "Cursor MCP calls must run the filter runner via nucleus-utils too")
    (assert' (
      (builtins.head cursorHooks.stop).command == "nucleus-utils harness-drive cursor"
    ) "Cursor stop must run harness-drive via nucleus-utils")

    # --- Per-action gates: master on, prompt approval, drive on ---
    # WHY: defaults are declared independently in nucleus-config implementations
    # and in the resolver scripts with nothing shared between them, so this file
    # pins declarations; script fallback gates are asserted by harness suites.
    (assert'
      (
        builtins.match ".*\"harness-approval\": [{][ ]*\"sources\": [[]\"prompt\"],.*" flatConfigSh != null
      )
      "nucleus-config DEFAULTS must ship harness-approval.sources=[\"prompt\"], so no host brokers a tool call until it opts in"
    )
    (assert' (builtins.match ".*\"harness-drive\": [{][^}]*\"enable\": true.*" flatConfigSh != null)
      "nucleus-config DEFAULTS must ship harness-drive.enable=true, so a finished turn is announced and remote driving keeps working"
    )
    (assert' (
      builtins.match ".*'harness-approval' = @[{][ ]*sources = @[(]'prompt'[)].*" flatConfigPs1 != null
    ) "the PowerShell nucleus-config DEFAULTS must ship the same harness-approval.sources=['prompt']")
    (assert'
      (
        builtins.match ".*'harness-approval' = @[{][ ]*sources[ ]*= @[(]'prompt'[)][ ]*'timeout-seconds' = @[{][ ]*hermes = 0; prompt = 0.*" flatApprovalScriptPs1
        != null
      )
      "harness-approval.ps1 carries its own copy of the defaults, and a hook that runs without a config file falls back to it, so it must ship the same source list and per-source timeouts"
    )
    (assert' (
      builtins.match ".*'harness-drive' += @[{][^}]*enable = \\$true.*" flatConfigPs1 != null
    ) "the PowerShell nucleus-config DEFAULTS must ship the same harness-drive.enable=true")

    # --- Source default parity ---
    (assert'
      (
        builtins.match ".*\"harness-approval\":[{]\"sources\":[[]\"prompt\"],\"timeout-seconds\":[{]\"hermes\":0,\"prompt\":0[}][}].*" flatApprovalScript
        != null
      )
      "harness-approval must ship the same source list and per-source timeouts as nucleus-config, since a hook that runs without a config file falls back to these"
    )
  ];

  success = true;
  message = "harness bridge wiring and default parity tests passed";
}
