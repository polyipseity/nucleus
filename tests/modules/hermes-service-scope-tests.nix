# tests/modules/hermes-service-scope-tests.nix: registry scope for the Windows
# Hermes gateway, which owns per-user secrets and profile state.
#
# Run with: nix-instantiate --eval --strict tests/modules/hermes-service-scope-tests.nix

let
  inherit (import ../lib.nix) assert';
  serviceEntry = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);

  tests = [
    (assert' (
      serviceEntry.hermes-agent.hosts.Windows.scope == "user"
    ) "Hermes Windows service must be user-scoped")
    (assert' (
      serviceEntry.hermes-agent.hosts.Windows.type == "windows-user-autostart"
    ) "Hermes Windows service must use user autostart")
  ];
in
{
  inherit tests;
  success = builtins.all (test: test == null) tests;
  message = "Hermes gateway uses Windows user autostart";
}
