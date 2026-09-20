# src/modules/lib/hermes-secrets.nix — Pure selection and coverage checks for the
# hermes-agent SOPS secrets.
#
# Free of `pkgs`, `lib` and file access on purpose: the two rules that decide
# whether the gateway starts authenticated have no runtime surface, so they are
# fixture-tested on their own (tests/modules/hermes-agent-tests.nix) instead of
# through a full NixOS evaluation.
#
#   1. which entries of the catalog the gateway consumes at all — `consumers`
#      containing "hermes-agent";
#   2. every declared key existing in the SOPS file of its own `sopsSource`,
#      because upstream builds `~/.hermes/.env` from the decrypted values.
#
# An entry that does not match the catalog schema fails the evaluation rather
# than being skipped: check step 7 reports the same file with the offending
# field named.
let
  sopsUtils = import ./sops-utils.nix;
  inherit (sopsUtils) missingSopsKeys;
in
{
  # Catalog entries the gateway consumes, grouped by the SOPS file they are
  # declared in.
  selectHermesSecrets =
    secrets:
    let
      all = builtins.filter (s: builtins.elem "hermes-agent" s.consumers) secrets;
    in
    {
      inherit all;
      system = builtins.filter (s: s.sopsSource == "system") all;
      # Grouped by name and not by exclusion: an entry is checked only against
      # the SOPS file its own `sopsSource` names, so a group never borrows the
      # other file's key list.
      user = builtins.filter (s: s.sopsSource == "user") all;
    };

  # Declared keys the referenced SOPS file does not carry.
  #
  # `systemKeys` and `userKeys` are the parsed key names of that file — `[ ]`
  # when it is absent, which reports every secret of the group rather than none.
  auditHermesSecrets =
    {
      groups,
      systemKeys,
      userKeys,
    }:
    let
      system = missingSopsKeys systemKeys groups.system;
      user = missingSopsKeys userKeys groups.user;
    in
    {
      inherit system user;
      all = system ++ user;
    };
}
