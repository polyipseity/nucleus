# src/modules/lib/users-overlay.nix — Generic per-user overlay path selection.
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
# The per-user path wins when it exists; otherwise the default applies.
rec {
  selectUserConfigSource = {
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

  selectUserConfigFile = {
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

  selectUserConfigDir = {
    configName,
    effectiveUsername,
    repoRoot,
  }:
    let
      perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}";
      default = "${repoRoot}/src/users/default/${configName}";
    in
    if builtins.pathExists perUser then perUser else default;
}
