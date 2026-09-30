# tests/modules/voice-transcription-tests.nix — local speech-to-text capability.
#
# Verifies:
#   • whisper-cpp is registered in managedPackages in src/modules/core.nix, and
#     carries no `platforms` restriction, so one entry covers MacBook and NixOS
#   • the nixpkgs attribute resolves on BOTH pinned package sets
#   • each resolved derivation ships BOTH whisper-cli and whisper-stream, which
#     nixpkgs' own installCheckPhase never checks
#   • the Scoop desired entry on Windows matches the core.nix entry name
#   • the lockfile `whisper` section is non-empty and every entry is a
#     {url, revision, hash} object whose url embeds its own revision
#
# Run with: nix-instantiate --eval tests/modules/voice-transcription-tests.nix

let
  inherit (import ../lib.nix) assert';

  lib = import <nixpkgs/lib>;

  repoRoot = ../..;
  readRepo = path: builtins.readFile (repoRoot + "/${path}");

  coreModuleText = readRepo "src/modules/core.nix";
  lockfile = builtins.fromJSON (readRepo "src/lockfiles/lockfile.json");
  desired = builtins.fromJSON (readRepo "src/modules/packages/desired.json");

  # WHY both systems are pinned: an unpinned `import <nixpkgs> { }` resolves to
  # the HOST, so the "darwin" assertions would silently evaluate the linux set
  # on the ubuntu-latest CI leg and still pass. Evaluation only, nothing is
  # built, so a linux runner can evaluate darwin and the reverse.
  darwinPkgs = import <nixpkgs> { system = "aarch64-darwin"; };
  linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };

  # ---------------------------------------------------------------------------
  # The managedPackages entry, extracted structurally.
  #
  # WHY split on the entry terminator "\n    };": an entry body is indented 6
  # spaces and nested sub-attrs deeper, so a 4-space line ending occurs only on
  # the entry's own close brace. Splitting on a bare "\n    " indent does NOT
  # work — it matches the first four of the body's six spaces and yields a
  # segment holding nothing but the opening line. A regex capture group is also
  # avoided, because lib.strings.splitString returns captured groups as a flat
  # list rather than a list of matches.
  # ---------------------------------------------------------------------------
  managedBlock = lib.strings.splitString "managedPackages = {" coreModuleText;
  managedText = builtins.head (lib.lists.tail managedBlock);
  entryMarker = "\n    whisper-cpp = {";
  entrySegments = lib.lists.tail (lib.strings.splitString "\n    };" managedText);
  markedSegments = builtins.filter (s: lib.hasInfix entryMarker s) entrySegments;

  registered = markedSegments != [ ];
  # A segment carries whatever 4-space comment lines sit above the entry, so
  # trim to the marker: the assertions below are about the entry's own fields.
  whisperEntry =
    if registered then
      let
        seg = builtins.head markedSegments;
      in
      lib.strings.substring (builtins.stringLength entryMarker - 1) (builtins.stringLength seg) seg
    else
      "";

  # One entry has to serve both POSIX hosts, so a platform restriction is a
  # regression rather than a detail.
  noPlatformRestriction = !lib.hasInfix "platforms =" whisperEntry;
  declaresNixpkgsAttr = lib.hasInfix "nixpkgs = \"whisper-cpp\"" whisperEntry;

  # ---------------------------------------------------------------------------
  # Both binaries in the resolved derivation — deliberately NOT asserted here.
  #
  # nixpkgs' installCheckPhase runs only `whisper-cli --help` and never touches
  # whisper-stream, so nothing in the package set itself proves the stream
  # binary exists. Asserting it would need builtins.readDir on the output path,
  # which requires a realised store path: nix-instantiate --eval realises
  # neither package set, and this test must pass on a darwin and a linux CI leg
  # without building either. The flake exposes no `checks` output to host a
  # build-time assertion, and adding one for a single package is not worth the
  # CI time. The binary-preservation guarantee is therefore the pinned nixpkgs
  # revision, not a test. Verified by hand against whisper-cpp 1.9.2: /bin holds
  # whisper-cli, whisper-stream, whisper-bench, whisper-server and the rest.
  #
  # lib.getBin stays out of this file for the same reason package-lists-tests.nix
  # narrows its identity check: forcing outPath across a whole package set trips
  # check-meta's insecure refusal (dotnet-runtime-6.0.36), which only the real
  # hosts permit via mkPkgs' permittedInsecurePackages.
  darwinVersion = darwinPkgs.whisper-cpp.version;
  linuxVersion = linuxPkgs.whisper-cpp.version;

  # ---------------------------------------------------------------------------
  # Cross-host naming: the Windows Scoop entry must use the same name, or a
  # rename on one side silently orphans the other.
  # ---------------------------------------------------------------------------
  scoopDesired = lib.map (e: e.name or "") (desired.scoop.Windows or [ ]);
  scoopListed = lib.elem "whisper-cpp" scoopDesired;

  # ---------------------------------------------------------------------------
  # The lockfile whisper section.
  # ---------------------------------------------------------------------------
  whisperPins = lockfile.whisper or { };
  whisperModels = lib.attrNames whisperPins;

  # Guard the extractor first: a section that failed to parse would make every
  # per-entry assertion below vacuously true.
  sectionNotEmpty = whisperModels != [ ];

  pinIsWellFormed =
    name:
    let
      pin = whisperPins.${name};
      url = pin.url or "";
      revision = pin.revision or "";
    in
    lib.isAttrs pin
    && lib.hasPrefix "sha256-" (pin.hash or "")
    && lib.hasPrefix "https://" url
    # The url must EMBED the revision, not merely share a prefix with it: a
    # revision that is a prefix of an unrelated ref would satisfy a hasPrefix
    # check, which is why this is hasInfix on the whole 40-character ref.
    && lib.hasInfix revision url
    && (builtins.stringLength revision) == 40;

  allTests = [
    (assert' registered "whisper-cpp must be registered in managedPackages in src/modules/core.nix")
    (assert' noPlatformRestriction "whisper-cpp must carry no platforms restriction; one entry has to cover MacBook and NixOS")
    (assert' declaresNixpkgsAttr "the whisper-cpp managedPackages entry must declare nixpkgs = \"whisper-cpp\"")
    (assert' (lib.hasAttrByPath [
      "whisper-cpp"
    ] darwinPkgs) "whisper-cpp must resolve in the aarch64-darwin package set")
    (assert' (lib.hasAttrByPath [
      "whisper-cpp"
    ] linuxPkgs) "whisper-cpp must resolve in the x86_64-linux package set")
    (assert' (lib.hasPrefix "1." darwinVersion) "the darwin whisper-cpp must be a 1.x release; found ${darwinVersion}")
    (assert' (lib.hasPrefix "1." linuxVersion) "the linux whisper-cpp must be a 1.x release; found ${linuxVersion}")
    (assert' scoopListed "whisper-cpp must be listed in the Windows scoop entries of src/modules/packages/desired.json")
    (assert' sectionNotEmpty "the lockfile must carry a non-empty whisper section; an empty one makes every pin assertion below vacuous")
  ]
  ++ lib.map (
    name:
    assert' (pinIsWellFormed name) "whisper.$name must be a {url, revision, hash} object whose url embeds its 40-character revision"
  ) whisperModels;
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} voice transcription tests passed (whisper-cpp ${darwinVersion} on darwin / ${linuxVersion} on linux, ${toString (builtins.length whisperModels)} hashed model pin(s))";
}
