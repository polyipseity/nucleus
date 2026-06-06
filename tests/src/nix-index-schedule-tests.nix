# tests/src/nix-index-schedule-tests.nix — Validate nix-index refresh cadence.
#
# Ensures both POSIX hosts keep nix-index refreshes on the repository-standard
# daily midnight schedule instead of drifting to a less frequent cadence.
#
# Run with: nix-instantiate --eval tests/src/nix-index-schedule-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;

  inherit (import ../lib.nix) assert';

  test_linux_nix_index_is_daily = assert' (
    containsRegex ''Description = "Daily nix-index database refresh";'' linuxText
    && containsRegex ''OnCalendar = "00:00:00";'' linuxText
    && !containsRegex ''OnCalendar = "Sun 00:00:00";'' linuxText
  ) "linux nix-index timer must run daily at 00:00";

  test_macos_nix_index_is_daily = assert' (
    containsRegex ''Label = "local.nix-index-update";'' macosText
    && containsRegex ''StartCalendarInterval = \[ \{ Hour = 0; Minute = 0; \} \];'' macosText
    && !containsRegex "Weekday = 0;" macosText
  ) "macOS nix-index launch agent must run daily at 00:00";

  allTests = [
    test_linux_nix_index_is_daily
    test_macos_nix_index_is_daily
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} nix-index schedule tests passed";
}
