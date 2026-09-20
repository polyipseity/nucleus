# tests/modules/harness-bridge-tests.nix — harness bridge wiring and default parity.
#
# The bridge answers harness hooks through bare command names, so one shared hook
# definition drives every platform.  Two failures this test makes loud:
#
#   1. a hook that names a command no platform deploys — a silent no-op inside
#      someone else's tool, where the user only notices the missing notification;
#   2. the entry points, the declared defaults, and the hook timeout budget
#      drifting apart — the approval wait is exactly why the hook timeout has to
#      stay larger than it.
#
# Run with: nix-instantiate --eval --strict tests/modules/harness-bridge-tests.nix

let
  inherit (import ../lib.nix) all assert' containsString;
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

  # WHY: neither invariant has a runtime surface to test against.  The hook either
  # answers inside its timeout or the harness kills it, and the channel default is
  # declared four times — bash, PowerShell, and two JSON literals — with no shared
  # value between them.  Comparing the declared text is the only available check,
  # so the literals below are quoted exactly and in order: reordering the channels
  # or dropping one fails the test.
  configSh = read "/scripts/config.sh";
  flatConfigSh = flatten configSh;
  flatConfigPs1 = flatten (read "/scripts/config.ps1");
  approvalScript = read "/src/scripts/notify/harness-approval.sh";
  approvalScriptPs1 = read "/src/scripts/notify/harness-approval.ps1";
  driveScript = read "/src/scripts/notify/harness-drive.sh";
  driveScriptPs1 = read "/src/scripts/notify/harness-drive.ps1";
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

    # --- Channel default parity ---
    (assert' (containsString "\"channels\": [\"telegram\", \"ntfy\", \"discord\"]" configSh) "nucleus-config DEFAULTS must offer every supported channel")
    (assert' (containsString "channels = @('telegram', 'ntfy', 'discord')" (read "/scripts/config.ps1")) "the PowerShell nucleus-config DEFAULTS must match the shell one")
    (assert' (containsString "\"channels\":[\"telegram\",\"ntfy\",\"discord\"]" (read "/src/scripts/notify/harness-notify.sh")) "harness-notify must mirror the nucleus-config channel default it fallbacks to")
    (assert' (containsString "@('telegram', 'ntfy', 'discord')" (read "/src/scripts/notify/harness-notify.ps1")) "the PowerShell harness-notify must mirror the same channel default")

    # --- Per-action gates: master on, approval off, drive on ---
    # WHY: each flag lives in every layer that reads it — the two nucleus-config
    # implementations plus a fallback literal inside each script — with nothing
    # shared between them, so the declared text is the only available check.  The
    # shipped state is deliberately "notify, do not broker": a host opts into
    # remote approvals, and never the other way round.
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

    (assert' (containsString "\"harness-approval\":{\"enable\":false,\"timeout-seconds\":120}" approvalScript) "harness-approval must fall back to its own gate being off, so a config that never names it cannot broker")
    (assert' (containsString "'harness-approval' = @{ enable = $false; 'timeout-seconds' = 120 }" approvalScriptPs1) "the PowerShell harness-approval must declare the same off-by-default gate")
    (assert' (containsString "\"harness-approval\".enable" approvalScript) "harness-approval must consult harness-approval.enable, not only the master flag")
    (assert' (containsString "$config['harness-approval'].enable" approvalScriptPs1) "the PowerShell harness-approval must read the same approval gate")

    (assert' (containsString "\"harness-drive\":{\"enable\":true}" driveScript) "harness-drive must fall back to driving being on, matching the shipped default")
    (assert' (
      builtins.match ".*'harness-drive' += @[{] enable = \\$true [}].*" (flatten driveScriptPs1) != null
    ) "the PowerShell harness-drive must declare the same drive gate")
    (assert' (containsString "\"harness-drive\".enable" driveScript) "harness-drive must consult harness-drive.enable before injecting a queued prompt")
    (assert' (containsString "$config['harness-drive'].enable" driveScriptPs1) "the PowerShell harness-drive must read the same drive gate")

    # The master flag stays the single switch on both paths: it is what makes a
    # whole-bridge rollback one flag flip, and it is why the two examples in the
    # host manuals still turn everything off.
    (assert' (containsString "\"harness-notify\".enable" driveScript) "harness-drive must keep the master flag as the single switch")
    (assert' (containsString "$config['harness-notify'].enable" driveScriptPs1) "the PowerShell harness-drive must keep the same master flag")

    # --- Approval window parity ---
    (assert' (approvalWindow == approvalScriptDefault)
      "harness-approval must declare the same timeout the nucleus-config default ships (${toString approvalWindow} vs ${toString approvalScriptDefault})"
    )
  ];

  success = true;
  message = "harness bridge wiring and default parity tests passed";
}
