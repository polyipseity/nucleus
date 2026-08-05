# tests/integration/cursor-config-bridge-tests.nix — Cursor ~/.cursor bridge wiring.

let
  inherit (import ../lib.nix) assert' containsRegex;

  cursorModuleText = builtins.readFile ../../src/modules/cursor.nix;
  cursorScriptText = builtins.readFile ../../src/scripts/configs/symlink-cursor-config.sh;
  activationDagText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  cursorConfigPs1Path = ../../src/hosts/Windows/modules/user/Sync-CursorConfig.ps1;

  allTests = [
    (assert' (containsRegex "symlink-cursor-config" cursorModuleText) "cursor.nix must declare symlink-cursor-config activation")
    (assert' (containsRegex "symlink-cursor-config.sh" cursorModuleText) "cursor.nix must invoke symlink-cursor-config.sh")
    (assert' (containsRegex "install-agent-skills" cursorModuleText) "cursor.nix must run after install-agent-skills")
    (assert' (containsRegex "\\.instructions\\.md" cursorScriptText) "cursor bridge script must map instructions to rules")
    (assert' (containsRegex "\\.mdc" cursorScriptText) "cursor bridge script must emit .mdc rule symlinks")
    (assert' (containsRegex "\\.agent\\.md" cursorScriptText) "cursor bridge script must map agent files")
    (assert' (containsRegex "\\.prompt\\.md" cursorScriptText) "cursor bridge script must map prompt files")
    (assert' (containsRegex "_nucleus_protect_symlink" cursorScriptText) "cursor bridge script must protect managed symlinks")
    (assert' (containsRegex "symlink-cursor-config" activationDagText) "activation-dag.nix must list symlink-cursor-config")
    (assert' (builtins.pathExists cursorConfigPs1Path) "Sync-CursorConfig.ps1 must exist")
  ];
in
{
  success = builtins.all (test: test == null) allTests;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cursor config bridge tests passed";
}
