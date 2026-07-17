# src/modules/lib/config-utils.nix — Shared config deployment helpers.
#
# Every config in src/modules/configs/ should use these helpers to ensure
# consistent deployment semantics across all POSIX hosts.
# See .agents/instructions/app-config-policy.instructions.md for the
# priority ordering and "why not #1" comment rule.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  # Resolve NUCLEUS_REPO_ROOT at eval time (set by apply.sh).
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  symlinkHardeningLib = builtins.readFile ../scripts/lib/symlink-hardening-lib.sh;
in
{
  # ---------------------------------------------------------------------------
  # deployWritableSymlink — Method 1 (default).
  # Creates an out-of-store symlink from targetPath → repoRelPath, wrapped
  # with protect/unprotect around linkGeneration so the symlink survives
  # home-manager rebuilds.
  #
  # name: unique identifier for activation entry names
  # repoRelPath: path relative to repo root, e.g. "src/modules/configs/foo/bar"
  # targetRelPath: path relative to $HOME, e.g. ".config/foo/bar"
  # ---------------------------------------------------------------------------
  deployWritableSymlink = name: repoRelPath: targetRelPath: {
    home.file."${targetRelPath}".source =
      config.lib.file.mkOutOfStoreSymlink "${repoRoot}/${repoRelPath}";

    home.activation."unprotectSymlink_${name}" = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      ${symlinkHardeningLib}
      _nucleus_unprotect_symlink "${name}" "$HOME/${targetRelPath}"
    '';

    home.activation."protectSymlink_${name}" = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${symlinkHardeningLib}
      _nucleus_protect_symlink "${name}" "$HOME/${targetRelPath}"
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
  deployReadonly = name: sourcePath: targetRelPath: {
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
}
