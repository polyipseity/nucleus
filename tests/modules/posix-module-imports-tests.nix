# tests/modules/posix-module-imports-tests.nix — POSIX module import wiring and age-key path drift.
#
# Commit f90f0943 consolidated the per-host Nix imports into
# src/modules/posix/default.nix and silently dropped two modules on the floor:
# sops.nix (the machine age-key derivation) and agent-host-shell.nix (the
# VS Code wrapper). Both were dead for weeks with nothing failing.
#
# Nothing can see this class by construction: an unreferenced Nix module is
# perfectly valid, so nix flake check cannot report it, PSSA obviously cannot,
# and nixos-rebuild does not warn either. A mass file move that drops an import
# is indistinguishable from a deliberate one. Only a test that enumerates the
# directory and compares it against the aggregator catches it, so that is what
# the first test below does.
#
# The rest bind facts that were only ever verified by hand: the allowlist
# cannot rot, cannot grow silently, and the machine age key path cannot drift
# between the three places that spell it (which is exactly how defect 1 arose).
#
# Run with: nix-instantiate --eval --strict tests/modules/posix-module-imports-tests.nix
# or: nix run ./src#test -- --only-steps=nix-tests

let
  inherit (import ../lib.nix) assert';

  lib = import <nixpkgs/lib>;

  # Index of the first element satisfying pred, or -1. Defined locally because
  # lib.findIndex does not exist in the pinned nixpkgs.
  indexWhere =
    pred: list:
    let
      indices = lib.genList (i: i) (builtins.length list);
      hits = lib.filter (i: pred (builtins.elemAt list i)) indices;
    in
    if hits == [ ] then -1 else builtins.head hits;

  # ---------------------------------------------------------------------------
  # 1. The orphan guard: directory contents vs aggregator imports.
  # ---------------------------------------------------------------------------

  posixDir = ../../src/modules/posix;

  # readDir sees every .nix file in the directory. default.nix is the aggregator
  # itself, not a member of the list it collects, so it is excluded explicitly
  # rather than being quietly absent.
  posixNixFiles = lib.filter (name: name != "default.nix" && lib.hasSuffix ".nix" name) (
    builtins.attrNames (builtins.readDir posixDir)
  );

  aggregatorText = builtins.readFile ./../../src/modules/posix/default.nix;

  # Only a real list entry counts as an import. The match is anchored to the
  # whole line so a COMMENTED-OUT import is not mistaken for a live one -- if
  # the import is commented out the module really is orphaned and the test must
  # fail. A loose substring match would hide exactly the failure we guard.
  # builtins.match returns only the capture group, so the extension is appended
  # back to line the names up with the directory listing.
  aggregatorImports =
    let
      lines = lib.strings.splitString "\n" aggregatorText;
      matched = lib.filter (m: m != null) (
        lib.map (line: builtins.match "^ *\\./([A-Za-z0-9_-]+)\\.nix *$" line) lines
      );
    in
    lib.sort (a: b: a < b) (lib.unique (lib.map (name: "${name}.nix") (lib.map builtins.head matched)));

  # Modules that are intentionally NOT aggregator members, because their options
  # do not exist on darwin. Every entry is justified inline and verified below
  # (the file must exist, and it must genuinely not be imported).
  hostScopedModules = [
    # ref: allow-and-deny-lists.instructions.md#D4 -- security.sudo is a
    # NixOS-only option, so the macOS-shared posix/ aggregator cannot carry
    # security.nix; the NixOS host imports it directly. T2 (self-prune): stale
    # entries error below, in test_allowlist_is_not_stale.
    "security.nix"
  ];

  # ---------------------------------------------------------------------------
  # 2. Make the allowlist self-verifying.
  # ---------------------------------------------------------------------------

  nixosHostText = builtins.readFile ./../../src/hosts/NixOS/default.nix;
  macbookHostText = builtins.readFile ./../../src/hosts/MacBook/default.nix;

  # ---------------------------------------------------------------------------
  # 3. Evaluate sops.nix on both platforms to prove the derivation is wired.
  # ---------------------------------------------------------------------------

  # BOTH package sets are pinned to an explicit system. An unpinned
  # `import <nixpkgs> { }` resolves to the HOST, so the "darwin" evaluation
  # would silently become x86_64-linux on the ubuntu-latest leg of the CI
  # matrix (.github/workflows/ci.yml) and take the NixOS branch in sops.nix.
  # Nothing would say why a test that is green on a MacBook is red on Linux.
  # Evaluation only -- nothing is built -- so a Linux runner can evaluate the
  # darwin package set, and a darwin runner can evaluate the linux one.
  darwinPkgs = import <nixpkgs> { system = "aarch64-darwin"; };
  linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };

  # The module is applied as a function and its result is used as a module, the
  # same shape agent-host-shell-tests.nix uses, so no specialArgs plumbing is
  # needed. `users` is a module ARGUMENT (the managed user attrs the group grant
  # iterates) and is distinct from the `users` OPTION the module writes to.
  # The host is selected purely by the pkgs passed in: sops.nix reads
  # stdenv.isDarwin, so linuxPkgs yields the NixOS shape (the nucleus-sops group
  # and a group: owner spec) and darwinPkgs yields the macOS shape (no group, a
  # user: owner spec). Verified by fault injection: pointing the darwin eval at
  # linuxPkgs fails the group assertion, so the two evals really do differ.
  evalSops =
    pkgs:
    lib.evalModules {
      modules = [
        (import ../../src/modules/posix/sops.nix {
          inherit lib pkgs;
          username = "testuser";
          users = {
            testuser = { };
          };
        })
        {
          options.users = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          options.system.activationScripts = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.lines);
            default = { };
          };
        }
      ];
    };

  nixosSops = evalSops linuxPkgs;
  darwinSops = evalSops darwinPkgs;

  nixosActivationText = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (_n: f: f.text or "") nixosSops.config.system.activationScripts
  );
  darwinActivationText = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (_n: f: f.text or "") darwinSops.config.system.activationScripts
  );

  # ---------------------------------------------------------------------------
  # 4. Path drift guard. The machine age key path is spelled in three
  #    independent sources. Each is extracted STRUCTURALLY and the three
  #    results are compared, so editing any one of them alone fails here.
  #    (Restating the literal as a search pattern would assert only that the
  #    string I already typed exists -- the tautology this file exists to avoid.)
  # ---------------------------------------------------------------------------

  # The double-quoted runs on a line, extracted structurally. builtins.split
  # returns capture groups as one-element lists interleaved with the string
  # pieces, so the groups are selected with builtins.isList and unwrapped --
  # the same shape package-parity-tests.nix uses. Filtering on "is a non-empty
  # string" instead silently keeps the empty group LISTS (an empty list is not
  # equal to an empty string) and yields a list of lists, which is what an
  # earlier version of this function did.
  isListElement = x: builtins.isList x;
  doubleQuoted =
    line:
    let
      parts = builtins.split "\"([^\"]+)\"" line;
    in
    map builtins.head (lib.filter isListElement parts);

  # Body of a shell function, located by line index rather than by guessing a
  # closing-brace delimiter. Delimiter splitting was tried first and did NOT
  # match, which silently pulled the entire remainder of lib.sh into the
  # extraction and compared dozens of unrelated strings.
  shellFunctionBody =
    text: header:
    let
      lines = lib.strings.splitString "\n" text;
      start = indexWhere (l: lib.hasInfix header l) lines;
      after = lib.lists.drop (start + 1) lines;
      closing = indexWhere (l: lib.trim l == "}") after;
    in
    lib.take closing after;

  # lib.sh: the two printf branches of nucleus_machine_age_key_path.
  libShText = builtins.readFile ./../../src/scripts/lib/lib.sh;
  libShFunctionLines = shellFunctionBody libShText "nucleus_machine_age_key_path() {";
  libShBranchLines = lib.filter (l: lib.hasInfix "printf" l) libShFunctionLines;
  libShPaths = lib.sort (a: b: a < b) (lib.unique (lib.concatMap doubleQuoted libShBranchLines));

  # secrets.nix: the two literals inside the sops.age block.
  secretsNixText = builtins.readFile ./../../src/modules/secrets.nix;
  secretsNixLines = lib.strings.splitString "\n" secretsNixText;
  sopsAgeStart = indexWhere (l: lib.hasInfix "sops.age = {" l) secretsNixLines;
  sopsAgeAfter = lib.lists.drop (sopsAgeStart + 1) secretsNixLines;
  sopsAgeClosing = indexWhere (l: lib.trim l == "};") sopsAgeAfter;
  sopsAgeLines = lib.take sopsAgeClosing sopsAgeAfter;
  secretsNixPaths = lib.sort (a: b: a < b) (lib.unique (lib.concatMap doubleQuoted sopsAgeLines));

  # derive-host-age-key.sh: the two age_dir branches, plus the filename the
  # script appends when it builds the key path. The match includes the opening
  # quote so `age_key_file="$age_dir/machine.txt"` is NOT selected -- it merely
  # mentions age_dir and holds a template, not a literal.
  deriveScriptText = builtins.readFile ./../../src/scripts/secrets/derive-host-age-key.sh;
  deriveAgeDirLines = lib.filter (l: lib.hasInfix "age_dir=\"" l) (
    lib.strings.splitString "\n" deriveScriptText
  );
  deriveScriptPaths = lib.sort (a: b: a < b) (
    lib.unique (lib.map (p: "${p}/machine.txt") (lib.concatMap doubleQuoted deriveAgeDirLines))
  );

  # ===========================================================================
  # Tests
  # ===========================================================================

  # The guard. Any module present on disk but absent from the aggregator, and
  # not justified in hostScopedModules, is an f90f0943-class orphan.
  test_no_posix_module_lost_its_importer =
    let
      orphans = lib.filter (n: !(lib.elem n hostScopedModules)) (
        builtins.filter (n: !(lib.elem n aggregatorImports)) posixNixFiles
      );
    in
    assert' (orphans == [ ])
      "every src/modules/posix/*.nix must be imported by posix/default.nix, or listed in hostScopedModules with a justification; unimported: ${lib.strings.concatStringsSep ", " orphans}";

  # The aggregator must not import something that does not exist, or the guard
  # above would pass while the config is broken.
  test_aggregator_imports_all_exist =
    assert' (lib.all (n: lib.elem n posixNixFiles) aggregatorImports)
      "posix/default.nix imports a module that does not exist in src/modules/posix/; check for a rename or a deleted file";

  # T2 self-prune: an allowlist entry whose file is gone is stale and errors.
  test_allowlist_is_not_stale =
    assert' (lib.all (n: lib.elem n posixNixFiles) hostScopedModules)
      "hostScopedModules lists a module that no longer exists in src/modules/posix/; a stale allowlist entry is an error, not a warning (T2)";

  # An allowlist entry that IS imported by the aggregator has stopped being
  # host-scoped, so listing it would mask a real orphan forever. This is what
  # stops the allowlist from growing silently.
  test_allowlist_does_not_mask_a_live_import =
    assert' (lib.all (n: !(lib.elem n aggregatorImports)) hostScopedModules)
      "hostScopedModules lists a module the aggregator actually imports; the exception is stale and must be removed, because it would hide a future orphan";

  # security.nix must be imported by the NixOS host, and by the macOS host it
  # must be absent from both the aggregator and the host. Without this the
  # allowlist would be satisfied by a module nobody imports at all.
  test_security_nix_is_host_scoped =
    assert'
      (
        lib.hasInfix "../../modules/posix/security.nix" nixosHostText
        && !(lib.elem "security.nix" aggregatorImports)
        && !(lib.hasInfix "posix/security.nix" macbookHostText)
      )
      "posix/security.nix must be imported directly by src/hosts/NixOS/default.nix and by neither the aggregator nor the MacBook host";

  # T1 verification, folded in here per review: the NixOS group must exist and
  # the derivation must be in the system activation.
  test_nixos_declares_the_sops_group =
    assert' (nixosSops.config.users.groups ? nucleus-sops)
      "posix/sops.nix must declare the nucleus-sops group on NixOS; derive-host-age-key.sh chowns the key to it and hard-fails without it";

  test_nixos_group_is_absent_on_darwin =
    assert' (!(darwinSops.config.users.groups ? nucleus-sops))
      "the nucleus-sops group is the NixOS owner spec; it must not be declared on darwin, where the key belongs to the primary user";

  test_nixos_activation_derives_the_machine_age_key =
    assert'
      (
        lib.hasInfix "derive-host-age-key.sh" nixosActivationText
        && lib.hasInfix "group:nucleus-sops" nixosActivationText
      )
      "the evaluated NixOS system activation must run derive-host-age-key.sh with the group:nucleus-sops owner spec";

  test_darwin_activation_derives_the_machine_age_key =
    assert'
      (
        lib.hasInfix "derive-host-age-key.sh" darwinActivationText
        && lib.hasInfix "user:testuser" darwinActivationText
      )
      "the evaluated darwin postActivation must run derive-host-age-key.sh with the user:<primary> owner spec";

  # Path drift. Compared as sets so an ordering change is not a failure, but a
  # value change in ANY ONE of the three sources is.
  test_lib_sh_resolver_matches_secrets_nix =
    assert' (libShPaths == secretsNixPaths)
      "nucleus_machine_age_key_path in src/scripts/lib/lib.sh must spell the same two paths as sops.age.keyFile in src/modules/secrets.nix; resolver=${lib.strings.concatStringsSep " | " libShPaths}, secrets.nix=${lib.strings.concatStringsSep " | " secretsNixPaths}";

  test_derivation_script_matches_secrets_nix =
    assert' (deriveScriptPaths == secretsNixPaths)
      "derive-host-age-key.sh must write the same two paths sops.age.keyFile declares; script=${lib.strings.concatStringsSep " | " deriveScriptPaths}, secrets.nix=${lib.strings.concatStringsSep " | " secretsNixPaths}";

  # Guard against the extractor itself silently finding nothing, which would
  # make the two comparisons above compare [ ] with [ ] and pass.
  test_lib_sh_paths_are_the_documented_pair =
    assert'
      (
        libShPaths == [
          "/Library/Application Support/nucleus/sops/age/machine.txt"
          "/var/lib/nucleus/sops/age/machine.txt"
        ]
      )
      "the path extractor found nothing to compare; a drift guard over two empty lists is a false green, so the extracted pair is asserted explicitly";

  # The non-emptiness guard for the secrets.nix side, stated on its own: this
  # asserts the extractor found the two branch literals. Asserting equality with
  # libShPaths here would merely repeat
  # test_lib_sh_resolver_matches_secrets_nix while looking like a second check.
  test_secrets_nix_path_extraction_is_not_empty =
    assert' (builtins.length secretsNixPaths == 2)
      "the secrets.nix extractor found ${toString (builtins.length secretsNixPaths)} path(s), not 2; a drift guard over two empty lists is a false green";

  allTests = [
    test_no_posix_module_lost_its_importer
    test_aggregator_imports_all_exist
    test_allowlist_is_not_stale
    test_allowlist_does_not_mask_a_live_import
    test_security_nix_is_host_scoped
    test_nixos_declares_the_sops_group
    test_nixos_group_is_absent_on_darwin
    test_nixos_activation_derives_the_machine_age_key
    test_darwin_activation_derives_the_machine_age_key
    test_lib_sh_resolver_matches_secrets_nix
    test_derivation_script_matches_secrets_nix
    test_lib_sh_paths_are_the_documented_pair
    test_secrets_nix_path_extraction_is_not_empty
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  moduleCount = builtins.length posixNixFiles;
  message = "All ${toString (builtins.length allTests)} POSIX module import tests passed (${toString (builtins.length posixNixFiles)} modules, ${toString (builtins.length aggregatorImports)} imported, ${toString (builtins.length hostScopedModules)} host-scoped)";
}
