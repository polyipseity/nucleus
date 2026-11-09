# tests/modules/scoop-manifest-hashes-tests.nix: Guard every Scoop manifest hash.
#
# The published Scoop schema constrains `hash` to a digest, but that check needs
# network, so a POSIX run without it never notices a placeholder. This test
# applies the same pattern offline, additionally requires every architecture
# block to carry a hash, so a new architecture cannot inherit an empty field,
# rejects a digest repeated inside one hash array, and refuses an `autoupdate`
# block, so a version bump cannot rewrite a URL and leave the previous digest in
# place.
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

  # WHY: the rejection and the failure message both read this one list, so the
  # rule cannot reject a value that its own message calls well formed.
  unique =
    values:
    builtins.foldl' (acc: value: if builtins.elem value acc then acc else acc ++ [ value ]) [ ] values;

  # WHY: a repeated digest is the one malformed shape whose printed array looks
  # well formed, so it is named as a repeat instead of leaving the reader to
  # compare the elements of a value that is already printed.
  repeatedValues =
    values:
    builtins.filter (value: builtins.length (builtins.filter (other: other == value) values) > 1) (
      unique values
    );

  describeBadSite =
    site:
    let
      repeats = if builtins.isList site.value then repeatedValues site.value else [ ];
    in
    "${site.label} = ${describeValue site.value}"
    + (if repeats == [ ] then "" else " (repeated digest: ${builtins.concatStringsSep ", " repeats})");

  # WHY: the count of distinct elements must equal the element count, because a
  # digest copied twice inside one array gives no second integrity check and
  # arrives from a copy-paste edit.
  distinctCount = values: builtins.length (unique values);

  # Mirrors definitions.hash in the Scoop schema: one digest, or a non-empty
  # array of distinct digests. The array branch there carries `uniqueItems:
  # true`, so a repeated digest is malformed and not merely redundant.
  hashWellFormed =
    value:
    if builtins.isString value then
      builtins.match hashPattern value != null
    else if builtins.isList value then
      value != [ ]
      && builtins.all (item: builtins.isString item && builtins.match hashPattern item != null) value
      && distinctCount value == builtins.length value
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
    "glaxnimate.json" = 1;
    "inter.json" = 1;
    "rip2.json" = 2;
    "sigrok-cli.json" = 1;
    "source-serif.json" = 1;
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
      "every Scoop manifest hash must be a digest, not a placeholder: ${builtins.concatStringsSep ", " (builtins.map describeBadSite badHashSites)}";

  # WHY: no manifest carries an array hash, so the array branch of
  # `hashWellFormed` is unreachable from manifest data and its uniqueness rule
  # would otherwise pass vacuously. A literal digest pair pins both directions:
  # one digest is well formed, and the same digest twice is not. The message
  # names the repeated digest through the same helper a manifest failure uses.
  sampleDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  sampleHashArray = [
    sampleDigest
    sampleDigest
  ];
  singleDigestArrayAccepted = hashWellFormed [ sampleDigest ];
  repeatedDigestArrayRejected = !hashWellFormed sampleHashArray;

  test_array_hash_uniqueness =
    assert' (singleDigestArrayAccepted && repeatedDigestArrayRejected)
      "an array hash must accept one digest (that digest is ${
        if singleDigestArrayAccepted then "accepted" else "rejected"
      }) and reject a repeat (the repeat is ${
        if repeatedDigestArrayRejected then "rejected" else "accepted"
      }): ${
        describeBadSite {
          label = "self-test";
          value = sampleHashArray;
        }
      }";

  # WHY: `autoupdate` rewrites `url` on a version bump and leaves every `hash`
  # untouched, so a bumped manifest ships a URL whose digest describes the
  # previous archive. Neither project publishes an extractable checksum, so the
  # bump has to run `nix store prefetch-file` for each digest. Refusing the block
  # keeps that step from being skipped, and for a manifest whose installer file
  # name carries the version it is the only in-repo reminder to edit that name.
  manifestsWithAutoupdate = builtins.filter (manifest: manifest.doc ? autoupdate) manifests;

  test_no_autoupdate =
    assert' (manifestsWithAutoupdate == [ ])
      "${builtins.concatStringsSep "; " (
        builtins.map (
          manifest:
          "scoop manifest ${manifest.name} must not carry autoupdate: a bump must recompute the digests with nix store prefetch-file and update the installer file name when it carries the version"
        ) manifestsWithAutoupdate
      )}";

  allTests = [
    test_hash_site_counts
    test_every_manifest_has_hash_site
    test_architecture_blocks_are_attrsets
    test_architectures_carry_hash
    test_hashes_well_formed
    test_array_hash_uniqueness
    test_no_autoupdate
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  inherit allTests;
  testCount = builtins.length allTests;
  success = builtins.all (t: t == null) allTests;
}
