# src/modules/lib/users-overlay.nix — Per-user homedir overlay path selection.
#
# App trees under src/users/<username>/ merge with src/users/default/<app>/ at
# first level only: each first-level file or directory is resolved independently;
# deeper paths inherit the chosen first-level entry in whole. Registry JSON
# domains use users-registry.nix instead.
#
# selectUserConfigSource: host-specific files at
#   src/users/<username>/<config>/<Host>.<ext>
# with src/users/default/<config>/<Host>.<ext> fallback.
#
# selectUserConfigFirstLevelEntry: one first-level name under <config>/.
#
# selectUserConfigFile: relative paths where the first segment selects the
# first-level overlay entry; remaining segments are resolved inside that entry.
#
# listUserConfigFirstLevelEntries: union of first-level names from user and
# default config dirs (user wins on name collision at resolve time).
#
# mkUserOverlay: binds effectiveUsername/repoRoot/hostName to the selectors.
let
  uniqueStrings =
    strings:
    builtins.attrNames (
      builtins.listToAttrs (
        map (name: {
          inherit name;
          value = true;
        }) strings
      )
    );

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
      prefix = repoRoot + "/";
      hasRepoPrefix =
        absolutePath: builtins.substring 0 (builtins.stringLength prefix) absolutePath == prefix;
      toRepoRelPath =
        absolutePath:
        if hasRepoPrefix absolutePath then
          builtins.substring (builtins.stringLength prefix) (
            builtins.stringLength absolutePath - builtins.stringLength prefix
          ) absolutePath
        else
          absolutePath;
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
