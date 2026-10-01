# src/modules/lib/users-overlay.nix — Per-user homedir overlay path selection.
#
# Overlay resolution is first-level only: each first-level file or directory is
# resolved independently, and deeper paths inherit that entry in whole. Registry
# JSON domains go through users-registry.nix instead.
#
# Case-insensitive deduplication is the weakest constraint that works on NTFS,
# POSIX, and Nix alike. Symlink detection follows symlinks
# (builtins.pathExists), matching POSIX -e and Windows Test-Path.
{ lib }:
let
  # Per-user entries are listed before default entries, so keeping the first
  # occurrence resolves a name collision in favour of the per-user tree.
  # O(n^2), but the list holds fewer than 20 entries.
  uniqueStrings =
    strings:
    let
      go =
        acc: name:
        let
          lower = lib.toLower name;
        in
        if builtins.any (x: lib.toLower x == lower) acc then acc else acc ++ [ name ];
      deduped = builtins.foldl' go [ ] strings;
    in
    builtins.sort (a: b: a < b) deduped;

  dropStrings =
    n: strings:
    if n <= 0 || strings == [ ] then strings else dropStrings (n - 1) (builtins.tail strings);

  splitRelativePath =
    relativePath: builtins.filter builtins.isString (builtins.split "/" relativePath);
in
rec {
  selectUserConfigSource =
    {
      configName,
      ext,
      hostName,
      effectiveUsername,
      repoRoot,
    }:
    let
      perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}/${hostName}.${ext}";
      default = "${repoRoot}/src/users/default/${configName}/${hostName}.${ext}";
    in
    if builtins.pathExists perUser then perUser else default;

  selectUserConfigFirstLevelEntry =
    {
      configName,
      entryName,
      effectiveUsername,
      repoRoot,
    }:
    let
      perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}/${entryName}";
      default = "${repoRoot}/src/users/default/${configName}/${entryName}";
    in
    if builtins.pathExists perUser then
      perUser
    else if builtins.pathExists default then
      default
    else
      builtins.throw "selectUserConfigFirstLevelEntry: no source for '${configName}/${entryName}' (user '${effectiveUsername}')";

  listUserConfigFirstLevelEntries =
    {
      configName,
      effectiveUsername,
      repoRoot,
    }:
    let
      perUserDir = "${repoRoot}/src/users/${effectiveUsername}/${configName}";
      defaultDir = "${repoRoot}/src/users/default/${configName}";
      readNames = dir: if builtins.pathExists dir then builtins.attrNames (builtins.readDir dir) else [ ];
    in
    uniqueStrings ((readNames perUserDir) ++ (readNames defaultDir));

  selectUserConfigFile =
    {
      configName,
      relativePath,
      effectiveUsername,
      repoRoot,
    }:
    let
      segments = splitRelativePath relativePath;
      firstSegment = builtins.head segments;
      restSegments = dropStrings 1 segments;
      entryRoot = selectUserConfigFirstLevelEntry {
        inherit
          configName
          effectiveUsername
          repoRoot
          ;
        entryName = firstSegment;
      };
      resolvedPath =
        if restSegments == [ ] then
          entryRoot
        else
          "${entryRoot}/${builtins.concatStringsSep "/" restSegments}";
    in
    if builtins.pathExists resolvedPath then
      resolvedPath
    else
      builtins.throw "selectUserConfigFile: no source for '${configName}/${relativePath}' (resolved '${resolvedPath}')";

  mkUserOverlay =
    {
      effectiveUsername,
      repoRoot,
      hostName ? null,
    }:
    let
      # WHY: under Nix flake eval the repo is copied into the store, so the literal
      # `repoRoot` prefix no longer matches and a naive strip returns an
      # absolute store path that seed-writable-symlink.sh then joins onto the
      # live repo root, producing a dangling symlink. Every nucleus repo has
      # `src/` at its root and every selector resolves under `src/`, so strip
      # through the `/src/` boundary.
      toRepoRelPath =
        absolutePath:
        let
          m = builtins.match ".*/src/(.*)" absolutePath;
        in
        if m == null then absolutePath else "src/" + builtins.head m;
      overlayArgs = {
        inherit effectiveUsername repoRoot;
      };
    in
    {
      inherit toRepoRelPath;
      selectFile =
        configName: relativePath:
        selectUserConfigFile {
          inherit configName relativePath;
          inherit (overlayArgs) effectiveUsername repoRoot;
        };
      selectFirstLevelEntry =
        configName: entryName:
        selectUserConfigFirstLevelEntry {
          inherit configName entryName;
          inherit (overlayArgs) effectiveUsername repoRoot;
        };
      listFirstLevelEntries =
        configName:
        listUserConfigFirstLevelEntries {
          inherit configName;
          inherit (overlayArgs) effectiveUsername repoRoot;
        };
      selectSource =
        configName: ext:
        if hostName == null then
          builtins.throw "mkUserOverlay.selectSource: hostName is required for ${configName}.${ext}"
        else
          selectUserConfigSource {
            inherit
              configName
              ext
              hostName
              effectiveUsername
              repoRoot
              ;
          };
    };
}
