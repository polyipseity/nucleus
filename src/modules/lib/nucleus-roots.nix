# Nucleus consolidated root paths and activation helpers (Phase 1).
#
# Nucleus owns at most two native roots per host (USER root + SYSTEM root)
# plus a ~/.nucleus hub for every user. All nucleus code references ONLY
# root paths, never physical conventional locations (/var/log/nucleus,
# ~/Library/Logs/nucleus, etc.).
#
#   macOS:   USER  ~/Library/Application Support/nucleus
#            SYSTEM /Library/Application Support/nucleus
#   NixOS:   USER  ~/.local/share/nucleus
#            SYSTEM /var/lib/nucleus
#
# Pure function (not a module): call with `lib` + `pkgs` to obtain the path
# derivations and shell-script-text helpers used by host activation.
{ lib, pkgs }:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  nucleusUserRootFor =
    userHome:
    if isDarwin then
      "${userHome}/Library/Application Support/nucleus"
    else
      "${userHome}/.local/share/nucleus";

  nucleusSystemRoot = if isDarwin then "/Library/Application Support/nucleus" else "/var/lib/nucleus";

  nucleusHubDirFor = userHome: "${userHome}/.nucleus";

  # root -> conventional symlinks (direction: root owns the symlink; the
  # conventional dir is the target). Also creates the physical conventional
  # dirs, since activation is the ONLY place that should do so.
  #
  # `userHome` is the target user's home. `userName` (optional) is chowned
  # onto the user-root symlinks + physical user dirs when provided (system
  # activation runs as root, so user-owned paths would otherwise be root).
  mkNucleusRootSymlinks =
    {
      userHome,
      userName ? null,
    }:
    let
      userRoot = nucleusUserRootFor userHome;
      systemRoot = nucleusSystemRoot;
      userLinks =
        if isDarwin then
          ''
            mkdir -p "${userHome}/Library/Logs/nucleus" "${userHome}/Library/State/nucleus"
            ln -sfn "${userHome}/Library/Logs/nucleus" "${userRoot}/logs"
            ln -sfn "${userHome}/Library/State/nucleus" "${userRoot}/state"
          ''
        else
          ''
            mkdir -p "${userHome}/.local/state/nucleus/log"
            ln -sfn "${userHome}/.local/state/nucleus/log" "${userRoot}/logs"
          '';
      systemLinks =
        if isDarwin then
          ''
            mkdir -p "/var/log/nucleus"
            ln -sfn "/var/log/nucleus" "${systemRoot}/logs"
          ''
        else
          ''
            mkdir -p "/var/log/nucleus" "/run/nucleus"
            ln -sfn "/var/log/nucleus" "${systemRoot}/logs"
            ln -sfn "/run/nucleus" "${systemRoot}/run"
          '';
      chownUser = lib.optionalString (userName != null) (
        if isDarwin then
          "chown -R \"${userName}:\" \"${userRoot}\" \"${userHome}/Library/Logs/nucleus\" \"${userHome}/Library/State/nucleus\""
        else
          "chown -R \"${userName}:\" \"${userRoot}\" \"${userHome}/.local/state/nucleus\""
      );
    in
    ''
      mkdir -p "${userRoot}" "${systemRoot}"
      ${userLinks}
      ${systemLinks}
      ${chownUser}
    '';

  # ~/.nucleus hub: user -> USER root, system -> SYSTEM root
  # (direction: ~/.nucleus -> roots; the hub owns the symlinks).
  mkNucleusHub =
    {
      userHome,
      userName ? null,
    }:
    let
      userRoot = nucleusUserRootFor userHome;
      systemRoot = nucleusSystemRoot;
      hubDir = nucleusHubDirFor userHome;
      chown = lib.optionalString (
        userName != null
      ) "chown \"${userName}:\" \"${hubDir}\" \"${hubDir}/user\" \"${hubDir}/system\"";
    in
    ''
      mkdir -p "${hubDir}"
      ln -sfn "${userRoot}" "${hubDir}/user"
      ln -sfn "${systemRoot}" "${hubDir}/system"
      ${chown}
    '';
in
{
  inherit
    nucleusUserRootFor
    nucleusSystemRoot
    nucleusHubDirFor
    mkNucleusRootSymlinks
    mkNucleusHub
    ;
}
