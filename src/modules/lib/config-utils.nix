# src/modules/lib/config-utils.nix — Shared config deployment helpers.
#
# Machine-wide configs in src/modules/configs/ and per-user homedir configs in
# src/users/ should use these helpers for consistent deployment semantics.
# See .agents/instructions/app-config-policy.instructions.md for the
# priority ordering and "why not #1" comment rule.
{
  lib,
  pkgs,
  ...
}:
let
  # Resolve NUCLEUS_REPO_ROOT at eval time (set by apply.sh). Used for
  # mkOutOfStoreSymlink source paths (build-time) and for lib sourcing paths
  # (baked into activation scripts at build time, resolved at runtime).

  activationBundle = pkgs.callPackage ./script-tree.nix { };
in
{
  # ---------------------------------------------------------------------------
  # deployWritableSymlink — Method 1 (default).
  # Creates an out-of-store symlink from $HOME/targetRelPath → the LIVE repo
  # source (resolved at activation time via seed-writable-symlink.sh), so repo
  # edits take effect without rebuild. The writable-vs-immutable decision is
  # owned solely by managedSymlinkPaths (home.nix) and applied by the
  # protect-out-of-store-symlinks activation entry — this helper does NOT call
  # protect/unprotect itself (that would duplicate managedSymlinkPaths).
  #
  # name: unique identifier for the activation entry name
  # repoRelPath: path relative to repo root, e.g. "src/modules/configs/foo/bar"
  # targetRelPath: path relative to $HOME, e.g. ".config/foo/bar"
  # ---------------------------------------------------------------------------
  deployWritableSymlink = name: repoRelPath: targetRelPath: {
    home.activation."seedSymlink_${name}" = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/${targetRelPath}" \
        "${repoRelPath}" \
    '';
  };

  # ---------------------------------------------------------------------------
  # deployReadonly — Method 2 (fallback).
  # Places a Nix-store copy (immutable) at the target path.
  #
  # name: unique identifier
  # sourcePath: path relative to src/modules, e.g. ./configs/foo/bar
  # targetRelPath: path relative to $HOME
  # ---------------------------------------------------------------------------
  deployReadonly = _: sourcePath: targetRelPath: {
    xdg.configFile."${targetRelPath}".source = sourcePath;
  };

  # ---------------------------------------------------------------------------
  # deployMerge — Method 3 (fallback).
  # Runs mergeScript (a shell script fragment) at activation time to merge
  # managed settings from sourcePath into the live targetPath.
  #
  # name: unique identifier
  # mergeScript: shell script string executed after writeBoundary
  # ---------------------------------------------------------------------------
  deployMerge = name: mergeScript: {
    home.activation."mergeConfig_${name}" = lib.hm.dag.entryAfter [ "writeBoundary" ] mergeScript;
  };

  # ---------------------------------------------------------------------------
  # deployUserWritableSymlink — Method 1 for per-user homedir configs.
  # Resolves the source via mkUserOverlay, then delegates to deployWritableSymlink
  # (which seeds the LIVE repo symlink at activation time).
  # ---------------------------------------------------------------------------
  deployUserWritableSymlink =
    name:
    {
      configName,
      relativePath,
      targetRelPath,
      overlay,
    }:
    let
      absoluteSource = overlay.selectFile configName relativePath;
      repoRelPath = overlay.toRepoRelPath absoluteSource;
    in
    deployWritableSymlink name repoRelPath targetRelPath;
}
