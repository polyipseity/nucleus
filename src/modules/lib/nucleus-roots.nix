# Nucleus consolidated root paths and activation helpers.
#
# At most two native roots per host, plus a ~/.nucleus hub per user. Code
# references only root paths, never the physical conventional locations they
# point at.
#
#   macOS:   USER  ~/Library/Application Support/nucleus
#            SYSTEM /Library/Application Support/nucleus
#   NixOS:   USER  ~/.local/share/nucleus
#            SYSTEM /var/lib/nucleus
#
# Pure function, not a module: call with `lib` + `pkgs`.
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

  # The root owns the symlink and the conventional directory is its target. The
  # physical conventional dirs are created here because activation is the only
  # place that should.
  #
  # `userName` is chowned onto the user-root symlinks and physical user dirs
  # when given, since system activation runs as root.
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

  # ~/.nucleus hub, pointing at the roots rather than the other way round.
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
