# src/modules/lib/hermes-secrets.nix — Pure selection and coverage checks for the
# hermes-agent SOPS secrets.
#
# No `pkgs`, `lib` or file access on purpose: the two rules that decide whether
# the gateway starts authenticated are fixture-tested on their own in
# tests/modules/hermes-agent-tests.nix. Both name SOPS paths and recipient
# groups, so treat those literals as part of the contract.
#   1. which catalog entries the gateway consumes, `consumers` containing
#      "hermes-agent";
#   2. every declared key existing in the SOPS file its own `sopsSource` names.
#
# An entry that does not match the catalog schema fails the evaluation instead
# of being skipped, so check step 7 reports the file and the offending field.
let
  sopsUtils = import ./sops-utils.nix;
  inherit (sopsUtils) missingSopsKeys;
in
{
  # Catalog entries the gateway consumes, grouped by their declared SOPS file.
  selectHermesSecrets =
    secrets:
    let
      all = builtins.filter (s: builtins.elem "hermes-agent" s.consumers) secrets;
    in
    {
      inherit all;
      system = builtins.filter (s: s.sopsSource == "system") all;
      # Grouped by name, not by exclusion: each entry is checked only against
      # the file its own `sopsSource` names.
      user = builtins.filter (s: s.sopsSource == "user") all;
    };

  # Declared keys the referenced SOPS file does not carry.
  #
  # `systemKeys` and `userKeys` are the parsed key names of that file, `[ ]`
  # when the file is absent, which reports every secret in the group.
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
