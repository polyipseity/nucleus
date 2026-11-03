# tests/modules/harness-bridge-tests.nix: harness bridge wiring and default parity.
#
# The bridge answers harness hooks through bare command names, so one shared hook
# definition drives every platform.  Two failures this test makes loud:
#
#   1. a hook that names a command no platform deploys: a silent no-op inside
#      someone else's tool, where the user only notices the missing notification;
#   2. the entry points, the declared defaults, and the hook timeout budget
#      drifting apart; the approval wait is exactly why the hook timeout has to
#      stay larger than it.
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
    "harness-notify"
  ];

  copilotHooks =
    (builtins.fromJSON (read "/src/users/default/agents/hooks/harness-notify.json")).hooks;
  cursorHooks = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).hooks;
  cursorVersion = (builtins.fromJSON (read "/src/users/default/cursor/hooks.json")).version;

  # Attr values of both files are lists of hook entries; flatten one level.
  allEntries = builtins.concatLists (
    builtins.attrValues copilotHooks ++ builtins.attrValues cursorHooks
  );

  # WHY: text reads, not behavior. The approval window has no runtime surface to
  # test against: the hook either answers inside its timeout or the harness kills
  # it, so the budget is parsed from both declarations and compared at the end of
  # the test list. The gate defaults pinned below are declared independently in
  # the two nucleus-config implementations.
  configSh = read "/scripts/config.sh";
  flatConfigSh = flatten configSh;
  flatConfigPs1 = flatten (read "/scripts/config.ps1");
  approvalScript = read "/src/scripts/notify/harness-approval.sh";
  approvalWindow = builtins.fromJSON (
    builtins.head (builtins.match ".*harness-approval[^0-9]*([0-9]+).*" (flatten configSh))
  );
  approvalScriptDefault = builtins.fromJSON (
    builtins.head (
      builtins.match ".*\"harness-approval\":[{]\"enable\":false,\"timeout-seconds\":([0-9]+)[}].*" (
        flatten approvalScript
      )
    )
  );

  # First word of a hook command: the entry point the harness resolves on PATH.
  entryPointOf = command: builtins.head (builtins.split " " command);
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
    (assert' (all (
      entry: builtins.elem (entryPointOf entry.command) entryPoints
    ) allEntries) "every hook command must start with a deployed harness-bridge entry point")
    (assert' (all (entry: builtins.match "[a-z0-9_-]+( [a-z0-9_-]+)*" entry.command != null) allEntries)
      "hook commands must be bare PATH-resolved names; an absolute path, home expansion, or environment reference cannot work on all three hosts"
    )

    # --- Timeout budget exceeds the approval wait ---
    (assert' (all (entry: entry ? timeout) allEntries) "every hook entry must declare a timeout")
    (assert' (all (entry: entry.timeout > approvalWindow) allEntries)
      "hook timeout (${toString (builtins.head allEntries).timeout}) must exceed the approval window (${toString approvalWindow}), or the harness kills the hook before a decision can arrive"
    )

    # --- Copilot wiring ---
    (assert' (
      builtins.length copilotHooks.PreToolUse == 1
    ) "VS Code Copilot must gate tool calls with exactly one PreToolUse hook")
    (assert' (
      (builtins.head copilotHooks.PreToolUse).command == "harness-approval hook copilot"
    ) "VS Code Copilot PreToolUse must ask harness-approval for the Copilot decision document")
    (assert' (
      (builtins.head copilotHooks.PreToolUse).type == "command"
    ) "VS Code Copilot PreToolUse must be a command hook")
    (assert' (
      builtins.length copilotHooks.Stop == 1
    ) "VS Code Copilot must drive turn ends with exactly one Stop hook")
    (assert' (
      (builtins.head copilotHooks.Stop).command == "harness-drive copilot"
    ) "VS Code Copilot Stop must run harness-drive, which notifies and injects a queued prompt")

    # --- Cursor wiring ---
    (assert' (cursorVersion == 1) "Cursor hook definitions must use config version 1")
    (assert' (
      (builtins.head cursorHooks.beforeShellExecution).command == "harness-approval hook cursor"
    ) "Cursor shell executions must ask harness-approval for the Cursor permission document")
    (assert' (
      (builtins.head cursorHooks.beforeMCPExecution).command == "harness-approval hook cursor"
    ) "Cursor MCP calls must ask harness-approval for the Cursor permission document")
    (assert' (
      (builtins.head cursorHooks.stop).command == "harness-drive cursor"
    ) "Cursor stop must run harness-drive, which notifies and injects a queued prompt")

    # --- Per-action gates: master on, approval off, drive on ---
    # WHY: the shipped state is deliberately "notify, do not broker": a host
    # opts into remote approvals, and never the other way round. Each flag is
    # declared in both nucleus-config implementations with nothing shared
    # between them, so this file pins the declarations; the scripts' own
    # fallback gates are asserted by the harness-notify, harness-approval, and
    # harness-drive suites.
    (assert'
      (builtins.match ".*\"harness-approval\": [{][^}]*\"enable\": false,.*" flatConfigSh != null)
      "nucleus-config DEFAULTS must ship harness-approval.enable=false, so no host brokers a tool call until it opts in"
    )
    (assert' (builtins.match ".*\"harness-drive\": [{][^}]*\"enable\": true.*" flatConfigSh != null)
      "nucleus-config DEFAULTS must ship harness-drive.enable=true, so a finished turn is announced and remote driving keeps working"
    )
    (assert' (
      builtins.match ".*'harness-approval' = @[{][^}]*enable = \\$false.*" flatConfigPs1 != null
    ) "the PowerShell nucleus-config DEFAULTS must ship the same harness-approval.enable=false")
    (assert' (
      builtins.match ".*'harness-drive' += @[{][^}]*enable = \\$true.*" flatConfigPs1 != null
    ) "the PowerShell nucleus-config DEFAULTS must ship the same harness-drive.enable=true")

    # --- Approval window parity ---
    (assert' (approvalWindow == approvalScriptDefault)
      "harness-approval must declare the same timeout the nucleus-config default ships (${toString approvalWindow} vs ${toString approvalScriptDefault})"
    )
  ];

  success = true;
  message = "harness bridge wiring and default parity tests passed";
}
