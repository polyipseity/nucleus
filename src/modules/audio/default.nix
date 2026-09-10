# Audio service modules.
#
# camilladsp.nix uses launchd.agents which only exists in HM on Darwin.
# lib.mkIf inside the module does not prevent option path validation
# — the module system still checks that launchd is a valid option even
# when the mkIf condition is false. Import must be conditional on host.
{ hostName, ... }:
{
  imports =
    if hostName == "MacBook" then [ ./camilladsp.nix ] else [ ];
}
