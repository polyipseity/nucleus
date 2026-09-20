# tests/modules/ssh-agent-env-tests.nix — the gpg-agent SSH socket reaches the
# surfaces nix-darwin does not cover.
#
# nix-darwin exports SSH_AUTH_SOCK for POSIX shells only, so the env catalog is
# the single source of truth that carries the same socket into the macOS GUI
# domain (macBookAllVars -> gui-env) and into the POSIX PowerShell profile (the
# pwsh.nix token). The Windows half of the same catalog entry is asserted by
# tests/integration/env-parity-tests.nix; the PowerShell profile behaviour is
# asserted by tests/scripts/pwsh-ssh-agent-profile-tests.sh.
let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  config = { };

  mkEnvVars =
    hostName:
    import ../../src/modules/lib/env-secrets.nix {
      inherit
        config
        pkgs
        lib
        hostName
        ;
      username = "test";
    };

  macBook = mkEnvVars "MacBook";
  nixos = mkEnvVars "NixOS";

  inherit (import ../lib.nix) assert';

  socketPath = "/Users/test/.gnupg/S.gpg-agent.ssh";

  guiLaunchctlLines = lib.filter (line: lib.hasInfix "SSH_AUTH_SOCK" line) (
    lib.splitString "\n" macBook.macBookAllVars
  );

  test_macbook_value_is_the_agent_socket = assert' (
    macBook.resolveValue "SSH_AUTH_SOCK" "MacBook" == socketPath
  ) "SSH_AUTH_SOCK must resolve to the gpg-agent socket for a MacBook user";

  test_no_value_on_other_hosts =
    assert'
      (
        nixos.resolveValue "SSH_AUTH_SOCK" "NixOS" == null
        && macBook.resolveValue "SSH_AUTH_SOCK" "Windows" == null
      )
      "SSH_AUTH_SOCK is macOS-only; hosts with their own agent must resolve it to null rather than inherit a macOS socket path";

  test_posix_shells_receive_it = assert' (
    macBook.allVars.SSH_AUTH_SOCK or null == socketPath
  ) "SSH_AUTH_SOCK must be part of the POSIX shell session variables";

  test_nixos_system_env_excludes_it = assert' (
    !(nixos.systemVars ? SSH_AUTH_SOCK)
  ) "a per-user agent socket must not enter the NixOS system environment";

  test_gui_domain_receives_it = assert' (
    guiLaunchctlLines == [
      "/bin/launchctl setenv SSH_AUTH_SOCK ${socketPath}"
    ]
  ) "the macOS GUI domain must receive SSH_AUTH_SOCK through macBookAllVars";

  test_entry_is_user_specific = assert' (macBook.catalog.SSH_AUTH_SOCK.userSpecific or false
  ) "the agent socket path is per-user data";
in
{
  ok =
    test_macbook_value_is_the_agent_socket == null
    && test_no_value_on_other_hosts == null
    && test_posix_shells_receive_it == null
    && test_nixos_system_env_excludes_it == null
    && test_gui_domain_receives_it == null
    && test_entry_is_user_specific == null;
}
