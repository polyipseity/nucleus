# tests/modules/harness-bridge-tests.nix: harness bridge wiring and default parity.
#
# The bridge answers harness hooks through bare command names, so one shared hook
# definition drives every platform.  Two failures this test makes loud:
#
#   1. a hook that names a command no platform deploys: a silent no-op inside
#      someone else's tool, where the user only notices the missing notification;
#   2. the entry points, the declared defaults, and the hook timeout budget
#      drifting apart; the approval wait is exactly why the hook timeout has to
#      cover it.
#
# Run with: nix-instantiate --eval --strict tests/modules/harness-bridge-tests.nix

let
  inherit (import ../lib.nix) all assert';
  root = ../..;
  read = path: builtins.readFile (root + path);
  flatten = builtins.replaceStrings [ "\n" "\r" "\t" ] [ " " " " " " ];

  # Every entry point needs a POSIX and a Windows implementation: the shared hook
  # definitions call them by bare name on all three hosts.
  entryPoints = [
    "harness-approval"
    "harness-drive"
    "harness-filter"
    "harness-notify"
  ];

  # The deletion guard ships beside the bridge in the same hook files. It is a
  # deployed PATH command in its own right rather than a bridge entry point: a
  # POSIX script in src/scripts, and on Windows a shim Sync-SafeDelete.ps1 writes
  # around its PowerShell implementation.
  guardCommand = "safe-delete-guard";
  hookCommands = entryPoints ++ [ guardCommand ];
  guardScript = "/src/scripts/safe-delete-guard.sh";
  guardWindowsImplementation = "/src/platforms/Windows/modules/user/Sync-SafeDeleteGuard.ps1";

  copilotHooks =
    (builtins.fromJSON (read "/src/users/default/agents/hooks/harness-notify.json")).hooks;
  cursorHooks = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).hooks;
  cursorVersion = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).version;

  # Claude nests command entries one level deeper than the other two files: each
  # event holds matcher groups, and each group holds the commands, so its
  # commands are collected separately instead of joining allEntries.
  claudeHooks = (builtins.fromJSON (read "/src/users/default/claude/settings.json")).hooks;
  claudeEntries = builtins.concatMap (groups: builtins.concatMap (group: group.hooks) groups) (
    builtins.attrValues claudeHooks
  );
  # The gate assert reads only PreToolUse: an all-events count would let a guard
  # on any other event satisfy the "gate tool calls" claim while never blocking
  # a tool call.
  claudePreToolUseEntries = builtins.concatMap (group: group.hooks) claudeHooks.PreToolUse;

  # Attr values of both files are lists of hook entries; flatten one level.
  allEntries = builtins.concatLists (
    builtins.attrValues copilotHooks ++ builtins.attrValues cursorHooks
  );

  # WHY: text reads, not behavior. The hook budget has no runtime surface to test
  # against: the hook either answers inside its timeout or the harness kills it, so
  # the ceiling is a declared number here and compared against every filter entry.
  # The gate defaults pinned below are declared independently in the two
  # nucleus-config implementations and in the resolver, which is why they are read
  # as text and compared instead of imported.
  hookCeiling = 3600;
  configSh = read "/scripts/config.sh";
  flatConfigSh = flatten configSh;
  flatConfigPs1 = flatten (read "/scripts/config.ps1");
  flatApprovalScript = flatten (read "/src/scripts/notify/harness-approval.sh");
  flatApprovalScriptPs1 = flatten (read "/src/scripts/notify/harness-approval.ps1");

  # First word of a hook command: the command the harness resolves on PATH.
  entryPointOf = command: builtins.head (builtins.split " " command);
  # Entries of one event list that run a given command, so a per-file check can
  # name the exact entry instead of assuming its position.
  entriesRunning =
    entries: command: builtins.filter (entry: entryPointOf entry.command == command) entries;
  # Exact command match: a harness wired to another harness's decision document, or
  # to an argument-less approval call, still starts with the entry point name, so
  # the first-word match above cannot catch it.
  entriesWithCommand = entries: command: builtins.filter (entry: entry.command == command) entries;
  filterEntries = builtins.filter (entry: entryPointOf entry.command == "harness-filter") (
    allEntries ++ claudeEntries
  );
in
{
  tests = builtins.filter (x: x != null) [
    # --- Entry points exist for both platforms ---
    (assert' (all (
      name: builtins.pathExists (root + "/src/scripts/notify/${name}.sh")
    ) entryPoints) "every harness-bridge entry point needs a POSIX implementation")
    (assert' (all (name: builtins.pathExists (root + "/src/scripts/notify/${name}.ps1")) entryPoints)
      "every harness-bridge entry point needs a Windows implementation, or the shared hook definitions cannot resolve on Windows"
    )

    # --- Hooks resolve by bare name, never by machine-specific path ---
    (assert'
      (all (entry: builtins.elem (entryPointOf entry.command) hookCommands) (allEntries ++ claudeEntries))
      "every hook command must start with a deployed command: a harness-bridge entry point or the deletion guard"
    )
    (assert'
      (all (entry: builtins.match "[a-z0-9_-]+( [a-z0-9_-]+)*" entry.command != null) (
        allEntries ++ claudeEntries
      ))
      "hook commands must be bare PATH-resolved names; an absolute path, home expansion, or environment reference cannot work on all three hosts"
    )
    (assert' (builtins.pathExists (root + guardScript))
      "the deletion guard hook needs its POSIX implementation, or a POSIX harness runs a hook it cannot find"
    )
    (assert' (builtins.pathExists (root + guardWindowsImplementation))
      "the deletion guard hook needs its Windows implementation, which Sync-SafeDelete.ps1 exposes as the safe-delete-guard shim; without it the guard is silent on Windows"
    )

    # --- Timeout budget covers the approval wait ---
    (assert' (all (entry: entry ? timeout) allEntries) "every hook entry must declare a timeout")
    (assert' (filterEntries != [ ])
      "the hook files must run the filter runner at least once, or the approval budget below is vacuous"
    )
    (assert' (all (entry: entry.timeout == hookCeiling) filterEntries)
      "a filter entry's timeout must be the hook ceiling (${toString hookCeiling} s); the approval sources wait until answered by default, so a shorter hook timeout turns a human's answer into a harness denial"
    )

    # --- Claude carries the same budget ---
    (assert' (builtins.length claudeEntries > 0)
      "the Claude hook config must declare at least one hook entry; an emptied hook set would make the timeout asserts below vacuous"
    )
    (assert' (
      builtins.length (entriesRunning claudePreToolUseEntries guardCommand) == 1
    ) "Claude must gate tool calls with exactly one safe-delete-guard hook")
    (assert' (all (entry: entry ? timeout) claudeEntries)
      "every Claude hook entry must declare a timeout, or the harness applies a budget of its own and the guard can be killed before the approval window"
    )

    # --- Copilot wiring ---
    (assert'
      (
        builtins.length copilotHooks.PreToolUse == 1
        && builtins.length (entriesWithCommand copilotHooks.PreToolUse "harness-filter copilot") == 1
      )
      "VS Code Copilot PreToolUse must run exactly the filter runner: one entry point makes the decision, so no second document can disagree with it"
    )
    (assert' (all (
      entry: entry.type == "command"
    ) copilotHooks.PreToolUse) "VS Code Copilot PreToolUse hooks must all be command hooks")
    (assert' (
      builtins.length copilotHooks.Stop == 1
    ) "VS Code Copilot must drive turn ends with exactly one Stop hook")
    (assert' (
      (builtins.head copilotHooks.Stop).command == "harness-drive copilot"
    ) "VS Code Copilot Stop must run harness-drive, which notifies and injects a queued prompt")

    # --- Cursor wiring ---
    (assert' (cursorVersion == 1) "Cursor hook definitions must use config version 1")
    (assert'
      (
        builtins.length cursorHooks.beforeShellExecution == 1
        &&
          builtins.length (entriesWithCommand cursorHooks.beforeShellExecution "harness-filter cursor") == 1
      )
      "Cursor shell executions must run exactly the filter runner: one entry point makes the decision, so no second document can disagree with it"
    )
    (assert'
      (
        builtins.length cursorHooks.beforeMCPExecution == 1
        && (builtins.head cursorHooks.beforeMCPExecution).command == "harness-filter cursor"
      )
      "Cursor MCP calls must run the filter runner too, because an MCP call can delete data just as a shell command can"
    )
    (assert' (
      (builtins.head cursorHooks.stop).command == "harness-drive cursor"
    ) "Cursor stop must run harness-drive, which notifies and injects a queued prompt")

    # --- Per-action gates: master on, prompt approval, drive on ---
    # WHY: the shipped state asks in the terminal and brokers nothing remotely: a
    # host adds the hermes source, and never the other way round. Each default is
    # declared in both nucleus-config implementations and in the resolver with
    # nothing shared between them, so this file pins the declarations; the
    # scripts' own fallback gates are asserted by the harness-notify,
    # harness-approval, and harness-drive suites.
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
