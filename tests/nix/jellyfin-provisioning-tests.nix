# tests/nix/jellyfin-provisioning-tests.nix — Validate Jellyfin provisioning parity.
#
# Ensures Jellyfin is provisioned declaratively on both Nix hosts and through
# WinGet on Windows so the media-server baseline stays aligned across hosts.
#
# Run with: nix-instantiate --eval tests/nix/jellyfin-provisioning-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  coreText = builtins.readFile ../../src/modules/core.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  windowsSystemText = builtins.readFile ../../src/hosts/Windows/system.dsc.yml;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  test_core_installs_jellyfin = assert' (containsRegex ''pkgs\.jellyfin'' coreText) "core.nix must install pkgs.jellyfin on Nix-managed hosts";

  test_linux_runs_jellyfin_service = assert' (
    containsRegex ''jellyfinMediaServer = pkgs\.writeShellScript "jellyfin-media-server"'' linuxText
    && containsRegex ''systemd\.user\.services\."jellyfin-media-server"'' linuxText
    && containsRegex ''ExecStart = "\$\{jellyfinMediaServer\}";'' linuxText
  ) "linux.nix must provision a Jellyfin systemd user service";

  test_macos_runs_jellyfin_agent = assert' (
    containsRegex ''jellyfinMediaServer = pkgs\.writeShellScript "jellyfin-media-server"'' macosText
    && containsRegex ''launchd\.agents\."jellyfin-media-server"'' macosText
    && containsRegex ''Label = "local\.jellyfin-media-server";'' macosText
  ) "macos.nix must provision a Jellyfin launch agent";

  test_windows_installs_jellyfin_server = assert' (containsRegex ''id: Jellyfin\.Server'' windowsSystemText) "Windows DSC must install Jellyfin.Server via WinGet";

  allTests = [
    test_core_installs_jellyfin
    test_linux_runs_jellyfin_service
    test_macos_runs_jellyfin_agent
    test_windows_installs_jellyfin_server
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Jellyfin provisioning tests passed";
}
