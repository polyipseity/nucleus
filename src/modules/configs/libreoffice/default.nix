# LibreOffice metadata-stripping baseline: configured across all platforms
# by merging managed entries into registrymodifications.xcu.
#
# RemovePersonalInfoOnSaving strips author, timestamps, and editing duration on
# save; clearing UserProfile/Data keeps identity fields out in the first place.
{
  lib,
  libreOfficeDefaultSettings,
  ...
}:
let
  # Each becomes an empty-string XCU entry under /org.openoffice.UserProfile/Data.
  userProfileDataFields = [
    "c"
    "country"
    "facsimiletelephonenumber"
    "givenname"
    "homephone"
    "initials"
    "l"
    "mail"
    "o"
    "office"
    "organisational-unit"
    "postalcode"
    "position"
    "sn"
    "state"
    "street"
    "telephonenumber"
    "title"
    "url"
  ];

  # XCU item path for user profile data.
  userProfilePath = "/org.openoffice.UserProfile/Data";

  # XCU item path for the save-time metadata stripping toggle.
  scriptingPath = "/org.openoffice.Office.Common/Security/Scripting";

  # Managed entries from the per-user overlay settings.
  removePersonalInfoEntries =
    if libreOfficeDefaultSettings.removePersonalInfoOnSave then
      [
        {
          path = scriptingPath;
          name = "RemovePersonalInfoOnSaving";
          value = "true";
        }
      ]
    else
      [ ];

  clearUserProfileEntries =
    if libreOfficeDefaultSettings.clearUserProfileData then
      map (field: {
        path = userProfilePath;
        name = field;
        value = "";
      }) userProfileDataFields
    else
      [ ];

  extraEntries = libreOfficeDefaultSettings.extraSettings or [ ];

  # Combined list of all managed XCU entries.
  libreOfficeManagedXcuEntries = removePersonalInfoEntries ++ clearUserProfileEntries ++ extraEntries;

  # Rendered as "path|name|value" triples.
  renderXcuEntry = entry: "${entry.path}|${entry.name}|${entry.value}";

  # Shell-escaped argument string for the merge script.
  libreOfficeMergeArgs = builtins.concatStringsSep " " (
    map (entry: lib.escapeShellArg (renderXcuEntry entry)) libreOfficeManagedXcuEntries
  );

  # Platform-specific XCU file paths.
  libreOfficeDarwinXcuPath = "$HOME/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu";
  libreOfficeLinuxXcuPath = "$HOME/.config/libreoffice/4/user/registrymodifications.xcu";
in
{
  inherit
    libreOfficeManagedXcuEntries
    libreOfficeMergeArgs
    libreOfficeDarwinXcuPath
    libreOfficeLinuxXcuPath
    ;
}
