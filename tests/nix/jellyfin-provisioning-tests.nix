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
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  macbookJellyfinText = builtins.readFile ../../src/hosts/MacBook/jellyfin.nix;
  nixosDefaultText = builtins.readFile ../../src/hosts/NixOS/default.nix;
  nixosJellyfinText = builtins.readFile ../../src/hosts/NixOS/jellyfin.nix;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  windowsSystemText = builtins.readFile ../../src/hosts/Windows/system.dsc.yml;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  test_core_installs_jellyfin = assert' (containsRegex ''pkgs\.jellyfin'' coreText) "core.nix must install pkgs.jellyfin on Nix-managed hosts";

  test_nixos_imports_host_jellyfin_module = assert' (containsRegex ''\./jellyfin\.nix'' nixosDefaultText) "NixOS host entrypoint must import ./jellyfin.nix";

  test_nixos_runs_shared_jellyfin_service = assert' (
    containsRegex ''services\.jellyfin'' nixosJellyfinText
    && containsRegex "enable = true" nixosJellyfinText
  ) "NixOS must provision Jellyfin as a host-level shared service";

  test_macbook_imports_host_jellyfin_module = assert' (containsRegex ''\./jellyfin\.nix'' macbookDefaultText) "MacBook host entrypoint must import ./jellyfin.nix";

  test_macbook_runs_shared_jellyfin_daemon = assert' (
    containsRegex ''launchd\.daemons\.jellyfin'' macbookJellyfinText
    && containsRegex ''state_root="/Users/Shared/Jellyfin"'' macbookJellyfinText
  ) "macOS must provision Jellyfin as a host-level shared launchd daemon";

  test_no_per_user_jellyfin_units = assert' (
    !containsRegex "jellyfin-media-server" linuxText && !containsRegex "jellyfin-media-server" macosText
  ) "Per-user Jellyfin units must not exist in shared linux.nix or macos.nix modules";

  test_windows_installs_jellyfin_server = assert' (containsRegex ''id: Jellyfin\.Server'' windowsSystemText) "Windows DSC must install Jellyfin.Server via WinGet";

  allTests = [
    test_core_installs_jellyfin
    test_nixos_imports_host_jellyfin_module
    test_nixos_runs_shared_jellyfin_service
    test_macbook_imports_host_jellyfin_module
    test_macbook_runs_shared_jellyfin_daemon
    test_no_per_user_jellyfin_units
    test_windows_installs_jellyfin_server
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Jellyfin provisioning tests passed";
}
