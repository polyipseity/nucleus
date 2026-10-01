# src/modules/lib/config-utils.nix: Shared config deployment helpers.
#
# Priority ordering and the "why not method 1" rule live in
# .agents/instructions/app-config-policy.instructions.md
{
  lib,
  pkgs,
  ...
}:
let
  activationBundle = pkgs.callPackage ./script-tree.nix { };
in
{
  # Out-of-store symlink to the LIVE repo source, so repo edits take effect
  # without a rebuild. The writable-vs-immutable decision is owned by
  # managedSymlinkPaths in home.nix; this helper never calls protect/unprotect.
  deployWritableSymlink = name: repoRelPath: targetRelPath: {
    home.activation."seedSymlink_${name}" = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/${targetRelPath}" \
        "${repoRelPath}" \
    '';
  };

  # Method 2: immutable Nix-store copy at the target path.
  deployReadonly = _: sourcePath: targetRelPath: {
    xdg.configFile."${targetRelPath}".source = sourcePath;
  };

  # Method 3: merge the managed subset into the live target at activation time.
  deployMerge = name: mergeScript: {
    home.activation."mergeConfig_${name}" = lib.hm.dag.entryAfter [ "writeBoundary" ] mergeScript;
  };

  # Method 1 for per-user homedir configs, resolved through the overlay.
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
