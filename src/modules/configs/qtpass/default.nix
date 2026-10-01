# QtPass settings baseline, shared across platforms unless the per-user overlay
# overrides them. Returns the merged settings plus the command fragments that
# apply them through `defaults` (macOS) or INI edits (Linux).
{
  lib,
  pkgs,
  passwordStoreDir,
  qtPassDefaultSettings,
  ...
}:
let
  # check-suppress:config-method: method 3 (merge) -- shared baseline from declarative JSON. The JSON is
  # canonical for both Nix (POSIX merge) and Windows activation, and the
  # settings land in platform-native stores (macOS defaults, Linux INI,
  # Windows registry), so a symlink does not apply.
  qtPassPlatformSettings = lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
    # Platform exception to the shared baseline.
    hideOnClose = false;
  };

  # Pin gpg to the managed gnupg so QtPass never resolves a garbage-collectable
  # store hash or a system gpg reading a different keyring. Windows resolves it
  # at runtime in Sync-QtPassConfig.ps1, which writes qtpass.json to the registry.
  qtPassManagedSettings = (qtPassDefaultSettings // qtPassPlatformSettings) // {
    gpgExecutable = lib.getExe pkgs.gnupg;
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
