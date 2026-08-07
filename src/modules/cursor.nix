# Declarative ~/.cursor directory layout: bridge to ~/.agents/ for shared
# agent assets and per-entry symlinks into src/users/<user>/cursor/ for
# Cursor-native JSON and hook scripts.
{
  config,
  lib,
  pkgs,
  managedUsername ? null,
  username ? null,
  ...
}:
let
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      config.home.username;

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  cursorConfigDir = overlay.selectDir "cursor";

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  home.activation = {
    # -------------------------------------------------------------------------
    # symlink-cursor-config
    # Ensures ~/.cursor/ is a real directory, then:
    #   - folder symlink skills/ -> ~/.agents/skills/
    #   - per-file extension-mapped symlinks for rules/, agents/, commands/
    #   - per-entry symlinks from src/users/<user>/cursor/ (hooks.json, mcp.json, …)
    # -------------------------------------------------------------------------
    symlink-cursor-config =
      lib.hm.dag.entryAfter
        [
          "symlink-agent-config"
          "install-agent-skills"
        ]
        ''
          "${activationBundle}/src/scripts/configs/symlink-cursor-config.sh" "${repoRoot}" "${cursorConfigDir}"
        '';
  };
}
