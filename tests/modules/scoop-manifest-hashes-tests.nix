# tests/modules/scoop-manifest-hashes-tests.nix: Guard every Scoop manifest hash.
#
# The published Scoop schema constrains `hash` to a digest, but that check needs
# network, so a POSIX run without it never notices a placeholder. This test
# applies the same pattern offline, and additionally requires every architecture
# block to carry a hash, so a new architecture cannot inherit an empty field.
#
# Run with: nix-instantiate --eval --strict tests/modules/scoop-manifest-hashes-tests.nix

let
  inherit (import ../lib.nix) assert';

  repoRoot = ../..;
  manifestDir = repoRoot + "/src/modules/scoop-manifests";

  # Mirrors definitions.hashPattern in the Scoop schema.
  # ref: https://raw.githubusercontent.com/ScoopInstaller/Scoop/master/schema.json
  hashPattern = "^([a-fA-F0-9]{64}|(sha1|sha256|sha512|md5):([a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}|[a-fA-F0-9]{128}))$";

  manifestNames = builtins.filter (name: builtins.match ".*[.]json" name != null) (
    builtins.attrNames (builtins.readDir manifestDir)
  );

  manifests = builtins.map (name: {
    inherit name;
    doc = builtins.fromJSON (builtins.readFile (manifestDir + "/${name}"));
  }) manifestNames;

  archNamesOf = manifest: builtins.attrNames (manifest.doc.architecture or { });

  # Every place a manifest can carry a digest, labelled so a failure names the
  # exact field instead of the file. A manifest may carry a top-level hash, an
  # architecture hash, or both, so both shapes are collected.
  hashSites =
    manifest:
    (
      if manifest.doc ? hash then
        [
          {
            label = "${manifest.name}: hash";
            value = manifest.doc.hash;
          }
        ]
      else
        [ ]
    )
    ++ builtins.concatMap (arch: [
      {
        label = "${manifest.name}: architecture.${arch}.hash";
        value = manifest.doc.architecture.${arch}.hash or null;
      }
    ]) (archNamesOf manifest);

  allHashSites = builtins.concatMap hashSites manifests;

  describeValue = site: if site.value == null then "<missing>" else toString site.value;

  hashWellFormed = site: builtins.match hashPattern (describeValue site) != null;

  badHashSites = builtins.filter (site: !hashWellFormed site) allHashSites;

  architectureHasHash =
    manifest: builtins.all (arch: manifest.doc.architecture.${arch} ? hash) (archNamesOf manifest);

  manifestsMissingArchHash = builtins.filter (m: !architectureHasHash m) manifests;

  # Vacuity guards: a manifest that stops being discovered, or an architecture
  # that stops being read, would otherwise satisfy every check above.
  expectedManifestCount = 2;
  expectedHashSiteCount = 3;

  test_hash_sites_discovered =
    assert'
      (
        builtins.length manifests == expectedManifestCount
        && builtins.length allHashSites == expectedHashSiteCount
      )
      "discovered ${toString (builtins.length manifests)} manifests and ${toString (builtins.length allHashSites)} hash fields, expected ${toString expectedManifestCount} and ${toString expectedHashSiteCount}";

  test_hashes_well_formed =
    assert' (badHashSites == [ ])
      "every Scoop manifest hash must be a digest, not a placeholder: ${
        builtins.concatStringsSep ", " (builtins.map (s: "${s.label} = ${describeValue s}") badHashSites)
      }";

  test_architectures_carry_hash =
    assert' (manifestsMissingArchHash == [ ])
      "every architecture block must carry a hash: ${
        builtins.concatStringsSep ", " (builtins.map (m: m.name) manifestsMissingArchHash)
      }";

  allTests = [
    test_hash_sites_discovered
    test_hashes_well_formed
    test_architectures_carry_hash
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  inherit allTests;
  testCount = builtins.length allTests;
  success = builtins.all (t: t == null) allTests;
}
