# src/modules/lib/users-overlay.nix — Per-user homedir overlay path selection.
#
# App trees under src/users/<username>/ override src/users/default/<app>/ when
# present. Registry JSON domains use users-registry.nix instead.
#
# selectUserConfigSource: host-specific files at
#   src/users/<username>/<config>/<Host>.<ext>
# with src/users/default/<config>/<Host>.<ext> fallback.
#
# selectUserConfigFile: non-host-specific files at
#   src/users/<username>/<config>/<relativePath>
# with src/users/default/<config>/<relativePath> fallback.
#
# selectUserConfigDir: per-user config root directory with default fallback.
#
# mkUserOverlay: binds effectiveUsername/repoRoot/hostName to the selectors.
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

  selectUserConfigFile =
    {
      configName,
      relativePath,
      effectiveUsername,
      repoRoot,
    }:
    let
      perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}/${relativePath}";
      default = "${repoRoot}/src/users/default/${configName}/${relativePath}";
    in
    if builtins.pathExists perUser then perUser else default;

  selectUserConfigDir =
    {
      configName,
      effectiveUsername,
      repoRoot,
    }:
    let
      perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}";
      default = "${repoRoot}/src/users/default/${configName}";
    in
    if builtins.pathExists perUser then perUser else default;

  mkUserOverlay =
    {
      effectiveUsername,
      repoRoot,
      hostName ? null,
    }:
    let
      prefix = repoRoot + "/";
      hasRepoPrefix =
        absolutePath:
        builtins.substring 0 (builtins.stringLength prefix) absolutePath == prefix;
      toRepoRelPath =
        absolutePath:
        if hasRepoPrefix absolutePath then
          builtins.substring (builtins.stringLength prefix) (
            builtins.stringLength absolutePath - builtins.stringLength prefix
          ) absolutePath
        else
          absolutePath;
    in
    {
      inherit toRepoRelPath;
      selectFile =
        configName: relativePath:
        selectUserConfigFile {
          inherit
            configName
            relativePath
            effectiveUsername
            repoRoot
            ;
        };
      selectDir =
        configName:
        selectUserConfigDir {
          inherit
            configName
            effectiveUsername
            repoRoot
            ;
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
