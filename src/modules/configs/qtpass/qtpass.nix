# QtPass settings baseline (screenshot-verified): shared across all platforms
# unless overridden by platform-specific or per-user settings.
# Platform overrides: hideOnClose=false on macOS; user overrides from flake.nix.
#
# This module returns the merged settings and the shell-command fragments for
# applying them via `defaults` (macOS) or INI-file manipulation (Linux).
#
# Dependencies:
#   - passwordStoreDir: resolved path to the password store root.
#   - userAppSettings: (appName -> attrset) helper that reads per-user overrides.
{
  lib,
  pkgs,
  passwordStoreDir,
  userAppSettings,
  ...
}:
let
  # Method 3 (merge) — shared baseline from declarative JSON. The JSON file is
  # the single source of truth consumed by both Nix (POSIX merge) and Windows
  # activation. QtPass settings are merged into platform-native stores
  # (macOS: defaults, Linux: INI, Windows: registry), so Method 1 (symlink)
  # does not apply.
  qtPassDefaultSettings = builtins.fromJSON (builtins.readFile ./qtpass.json);

  qtPassPlatformSettings = lib.optionalAttrs pkgs.stdenv.isDarwin {
    # macOS keeps Hide on close disabled, per the requested platform-specific
    # exception to the shared QtPass baseline.
    hideOnClose = false;
  };

  qtPassManagedSettings =
    (qtPassDefaultSettings // qtPassPlatformSettings // (userAppSettings "qtpass"))
    // {
      passStore = "${lib.removeSuffix "/" passwordStoreDir}/";
    };

  renderQtPassValue =
    value:
    if builtins.isBool value then
      if value then "true" else "false"
    else if builtins.isInt value then
      toString value
    else
      value;

  renderQtPassDefaultsCommand =
    name: value:
    let
      renderedValue = renderQtPassValue value;
      valueArg = lib.escapeShellArg renderedValue;
      valueFlag =
        if builtins.isBool value then
          "-bool"
        else if builtins.isInt value then
          "-int"
        else
          "-string";
    in
    "/usr/bin/defaults write com.ijhack.QtPass ${name} ${valueFlag} ${valueArg}";

  renderQtPassIniCommand =
    confVar: name: value:
    let
      renderedValue = renderQtPassValue value;
      valueArg =
        if builtins.isString value then
          ''"$(_escape_qsettings_ini_string ${lib.escapeShellArg renderedValue})"''
        else
          lib.escapeShellArg renderedValue;
    in
    ''_update_qtpass_ini_value "${confVar}" "${name}" ${valueArg}'';

  qtPassDarwinCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList renderQtPassDefaultsCommand qtPassManagedSettings
  );

  qtPassPrimaryIniCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: renderQtPassIniCommand "$_primary_conf" name value
    ) qtPassManagedSettings
  );

  qtPassSecondaryIniCommands = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: renderQtPassIniCommand "$_secondary_conf" name value
    ) qtPassManagedSettings
  );
in
{
  inherit
    qtPassDarwinCommands
    qtPassDefaultSettings
    qtPassManagedSettings
    qtPassPlatformSettings
    qtPassPrimaryIniCommands
    qtPassSecondaryIniCommands
    renderQtPassDefaultsCommand
    renderQtPassIniCommand
    renderQtPassValue
    ;
}
