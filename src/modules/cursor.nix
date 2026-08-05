# Declarative ~/.cursor directory layout: bridge to ~/.agents/ for shared
# agent assets and per-entry symlinks into src/modules/configs/cursor/ for
# Cursor-native JSON and hook scripts.
{
  lib,
  pkgs,
  ...
}:
let
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  cursorConfigRelativePath = "src/modules/configs/cursor";
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  home.activation = {
    # -------------------------------------------------------------------------
    # symlink-cursor-config
    # Ensures ~/.cursor/ is a real directory, then:
    #   - folder symlink skills/ -> ~/.agents/skills/
    #   - per-file extension-mapped symlinks for rules/, agents/, commands/
    #   - per-entry symlinks from src/modules/configs/cursor/ (hooks.json, mcp.json, …)
    # -------------------------------------------------------------------------
    symlink-cursor-config =
      lib.hm.dag.entryAfter
        [
          "symlink-agent-config"
          "install-agent-skills"
        ]
        ''
          "${activationBundle}/src/scripts/configs/symlink-cursor-config.sh" "${repoRoot}" "${cursorConfigRelativePath}"
        '';
  };
}
