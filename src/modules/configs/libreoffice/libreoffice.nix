# LibreOffice metadata-stripping baseline: configured across all platforms
# by merging managed entries into registrymodifications.xcu.
#
# Two managed settings:
#   1. RemovePersonalInfoOnSave — strips author, timestamps, editing duration
#      from document properties on save.
#   2. UserProfile/Data cleared — removes identity fields (name, email, company)
#      so metadata is never embedded in the first place.
#
# Dependencies:
#   - libreOfficeDefaultSettings: parsed baseline from the per-user overlay JSON file.
{
  lib,
  libreOfficeDefaultSettings,
  ...
}:
let
  # User Data fields to clear. Each becomes an empty-string XCU entry
  # under /org.openoffice.UserProfile/Data.
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

  # Build the managed entries from the per-user overlay settings.
  removePersonalInfoEntries =
    if libreOfficeDefaultSettings.removePersonalInfoOnSave then
      [
        {
          path = scriptingPath;
          name = "RemovePersonalInfoOnSave";
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

  # Render entries into "path|name|value" triples for the merge script.
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
