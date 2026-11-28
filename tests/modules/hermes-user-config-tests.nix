# tests/modules/hermes-user-config-tests.nix: pinned declarations for the
# Hermes CLI and gateway profiles in the user-scope module.
#
# Run with: nix-instantiate --eval --strict tests/modules/hermes-user-config-tests.nix

let
  inherit (import ../lib.nix) all assert';
  moduleText = builtins.readFile ../../src/modules/hermes-agent.nix;

  # A small substring check keeps this suite pure: no nixpkgs import and no
  # regex escaping of the Nix expressions the module must declare.
  contains =
    needle: haystack:
    let
      n = builtins.stringLength needle;
      h = builtins.stringLength haystack;
      go =
        i:
        if i + n > h then
          false
        else if builtins.substring i n haystack == needle then
          true
        else
          go (i + 1);
    in
    go 0;

  declarations = [
    "services.hermes-agent.settings.terminal.backend = \"local\""
    "services.hermes-agent.settings.approvals.mode = \"smart\""
    "services.hermes-agent.gateway.enable = hostName == \"MacBook\" || hostName == \"NixOS\" || hostName == \"Windows\""
  ];

  tests = builtins.filter (x: x != null) (
    map (
      declaration:
      assert' (contains declaration moduleText) "hermes-agent.nix must declare: ${declaration}"
    ) declarations
  );
in
{
  inherit tests;
  success = all (test: test == null) tests;
  message = "Hermes user config declarations are present";
}
