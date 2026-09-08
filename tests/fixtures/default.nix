# Policy: tests must not reference real src/users/<username>/ identities — use test-user fixture only.
{
  lib ? import <nixpkgs/lib>,
}:
let
  fixtureRepoRoot = ./user-registry;
  fixtureUsername = "test-user";
  loadFixtureRegistry =
    hostName:
    import ../../src/modules/lib/users-registry.nix {
      inherit lib hostName;
      repoRoot = fixtureRepoRoot;
    };
in
{
  inherit fixtureRepoRoot fixtureUsername loadFixtureRegistry;
}
