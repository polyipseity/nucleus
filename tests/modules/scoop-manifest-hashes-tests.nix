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

  # WHY: every place a manifest can carry a digest is labelled with its field, so
  # a failure names that field instead of only the file. A manifest carries a
  # top-level hash, per-architecture hashes, or both, and the schema allows
  # either shape.
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
    ++ builtins.concatMap (
      arch:
      let
        block = manifest.doc.architecture.${arch};
      in
      # WHY: a block that is not an attribute set cannot carry `hash`, and
      # `.hash or` would raise instead of reporting it, so it is skipped here and
      # named by the architecture-block assertion.
      if builtins.isAttrs block then
        [
          {
            label = "${manifest.name}: architecture.${arch}.hash";
            value = block.hash or null;
          }
        ]
      else
        [ ]
    ) (archNamesOf manifest);

  allHashSites = builtins.concatMap hashSites manifests;

  # WHY: `toString` renders a list by joining its elements with spaces, which
  # would report a legitimate array hash as one malformed digest. Lists are
  # described element-wise, and any other type is named by its type rather than
  # given invented text.
  describeValue =
    value:
    if value == null then
      "<missing>"
    else if builtins.isString value then
      value
    else if builtins.isList value then
      "[ ${builtins.concatStringsSep ", " (builtins.map describeValue value)} ]"
    else
      "<${builtins.typeOf value}>";

  # Mirrors definitions.hash in the Scoop schema: one digest, or a non-empty
  # array of digests.
  hashWellFormed =
    value:
    if builtins.isString value then
      builtins.match hashPattern value != null
    else if builtins.isList value then
      value != [ ]
      && builtins.all (item: builtins.isString item && builtins.match hashPattern item != null) value
    else
      false;

  badHashSites = builtins.filter (site: !hashWellFormed site.value) allHashSites;

  nonAttrArchBlocks = builtins.concatMap (
    manifest:
    builtins.map (arch: "${manifest.name}: architecture.${arch}") (
      builtins.filter (arch: !builtins.isAttrs manifest.doc.architecture.${arch}) (archNamesOf manifest)
    )
  ) manifests;

  architectureHasHash =
    manifest:
    builtins.all (
      arch:
      let
        block = manifest.doc.architecture.${arch};
      in
      !builtins.isAttrs block || block ? hash
    ) (archNamesOf manifest);

  manifestsMissingArchHash = builtins.filter (m: !architectureHasHash m) manifests;

  manifestsWithoutHashSite = builtins.filter (manifest: hashSites manifest == [ ]) manifests;

  # WHY: vacuity guards. A manifest that stops being discovered, or an
  # architecture that stops being read, would otherwise satisfy every check
  # above, so each manifest's hash-site count is pinned by name. A reshape is a
  # one-line edit here, and a mismatch names the manifest.
  expectedHashSites = {
    "rip2.json" = 2;
    "sigrok-cli.json" = 1;
  };

  siteCounts = builtins.map (manifest: {
    inherit (manifest) name;
    count = builtins.length (hashSites manifest);
  }) manifests;

  countMismatches = builtins.filter (
    entry:
    !builtins.hasAttr entry.name expectedHashSites || expectedHashSites.${entry.name} != entry.count
  ) siteCounts;

  siteCountProblems =
    builtins.map (
      entry:
      if builtins.hasAttr entry.name expectedHashSites then
        "${entry.name} has ${toString entry.count} hash sites, expected ${
          toString expectedHashSites.${entry.name}
        }"
      else
        "${entry.name} is not in the expected map"
    ) countMismatches
    # WHY: an expected name that matches no discovered manifest would otherwise
    # pass vacuously, so the map is checked against the directory too.
    ++ builtins.map (name: "${name} is in the expected map but was not discovered") (
      builtins.filter (name: !builtins.elem name manifestNames) (builtins.attrNames expectedHashSites)
    );

  test_hash_site_counts =
    assert' (siteCountProblems == [ ])
      "hash site counts must match the expected map: ${builtins.concatStringsSep ", " siteCountProblems}";

  test_every_manifest_has_hash_site =
    assert' (manifestsWithoutHashSite == [ ])
      "every Scoop manifest must declare a top-level hash or an architecture hash: ${
        builtins.concatStringsSep ", " (builtins.map (manifest: manifest.name) manifestsWithoutHashSite)
      }";

  test_architecture_blocks_are_attrsets =
    assert' (nonAttrArchBlocks == [ ])
      "every architecture block must be an attribute set: ${builtins.concatStringsSep ", " nonAttrArchBlocks}";

  test_architectures_carry_hash =
    assert' (manifestsMissingArchHash == [ ])
      "every architecture block must carry a hash: ${
        builtins.concatStringsSep ", " (builtins.map (m: m.name) manifestsMissingArchHash)
      }";

  test_hashes_well_formed =
    assert' (badHashSites == [ ])
      "every Scoop manifest hash must be a digest, not a placeholder: ${
        builtins.concatStringsSep ", " (
          builtins.map (s: "${s.label} = ${describeValue s.value}") badHashSites
        )
      }";

  allTests = [
    test_hash_site_counts
    test_every_manifest_has_hash_site
    test_architecture_blocks_are_attrsets
    test_architectures_carry_hash
    test_hashes_well_formed
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  inherit allTests;
  testCount = builtins.length allTests;
  success = builtins.all (t: t == null) allTests;
}
