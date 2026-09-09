# Audio service modules.
#
# camilladsp.nix defines launchd.agents (Darwin-only HM option).
# It must not be imported on NixOS where launchd does not exist.
{ hostName, ... }:
{
  imports =
    # camilladsp.nix uses launchd.agents which only exists in HM on Darwin.
    # lib.mkIf inside the module is insufficient — the module system validates
    # option paths even when mkIf condition is false.
    if hostName == "MacBook" then [ ./camilladsp.nix ] else [ ];
}
