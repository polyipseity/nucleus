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

  singleQuoted =
    line:
    let
      parts = builtins.split "'([^']+)'" line;
    in
    map builtins.head (lib.filter isListElement parts);

  isMachinePath = p: builtins.match ".*/sops/age/machine\\.txt" p != null;

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

  # Path drift. The path is no longer spelled in three places: lib.sh and
  # derive-host-age-key.sh derive it, taking the system root from the
  # services.json manifest. The one remaining literal is the Nix side, which
  # is now checked against the manifest instead of against a restated copy of
  # itself -- so a root change in the manifest is caught here rather than
  # needing a second edit in a second language.
  libShText = builtins.readFile ./../../src/scripts/lib/lib.sh;
  libShFunctionLines = shellFunctionBody libShText "nucleus_machine_age_key_path() {";

  deriveScriptText = builtins.readFile ./../../src/scripts/secrets/derive-host-age-key.sh;
  deriveScriptLines = lib.strings.splitString "\n" deriveScriptText;

  # secrets.nix: the two literals in the machineAgeKeyPath binding.
  secretsNixText = builtins.readFile ./../../src/modules/secrets.nix;
  secretsNixLines = lib.strings.splitString "\n" secretsNixText;
  machineKeyStart = indexWhere (l: lib.hasInfix "machineAgeKeyPath =" l) secretsNixLines;
  machineKeyAfter = lib.lists.drop (machineKeyStart + 1) secretsNixLines;
  machineKeyClosing = indexWhere (l: lib.hasInfix ";" l) machineKeyAfter;
  machineKeyLines = lib.take (machineKeyClosing + 1) machineKeyAfter;
  secretsNixPaths = lib.sort (a: b: a < b) (lib.unique (lib.concatMap doubleQuoted machineKeyLines));

  # The expected paths, computed from the manifest rather than restated here.
  # Only the two POSIX hosts: secrets.nix is evaluated through Home Manager,
  # which Windows does not use, and the Windows root is a %ProgramData%
  # template that is not a POSIX path at all.
  loggingConfig =
    (builtins.fromJSON (builtins.readFile ./../../src/modules/services.json))."$logging";

  # step-runner.ps1 is cross-platform and cannot call the shell resolver, so it
  # carries the POSIX roots as literals. Those are the one remaining unguarded
  # duplication, pinned here. The PowerShell source quotes them singly, which
  # is why this needs singleQuoted and not doubleQuoted.
  stepRunnerText = builtins.readFile ./../../src/scripts/lib/step-runner.ps1;
  stepRunnerPosixPaths = lib.sort (a: b: a < b) (
    lib.unique (
      lib.filter isMachinePath (lib.concatMap singleQuoted (lib.strings.splitString "\n" stepRunnerText))
    )
  );
  manifestPaths = lib.sort (a: b: a < b) (
    lib.map (host: "${builtins.dirOf loggingConfig.${host}.systemLogDir}/sops/age/machine.txt") [
      "MacBook"
      "NixOS"
    ]
  );

  # The Windows suffix is the one duplication left standing, in two PowerShell
  # consumers. It is not shared by a constant because Get-Secret.ps1 is
  # dot-sourced with a param() block, and PowerShell requires param() to come
  # first, so a dot-sourced constant cannot reach a parameter default. Removing
  # the duplication instead means restructuring the secret-decryption path on
  # the one platform with no local test coverage, which costs more than the
  # 24 characters it saves. So the suffix is pinned, not eliminated. A single
  # quoted string containing a backslash: the POSIX literals in the same file
  # are forward-slashed, so the backslash is what discriminates them.
  isWindowsSuffix = p: builtins.match ".*\\\\machine\\.txt" p != null;
  getSecretText = builtins.readFile ./../../src/platforms/Windows/modules/secrets/Get-Secret.ps1;
  windowsSuffixInGetSecret = lib.sort (a: b: a < b) (
    lib.unique (
      lib.filter isWindowsSuffix (lib.concatMap singleQuoted (lib.strings.splitString "\n" getSecretText))
    )
  );
  windowsSuffixInStepRunner = lib.sort (a: b: a < b) (
    lib.unique (
      lib.filter isWindowsSuffix (
        lib.concatMap singleQuoted (lib.strings.splitString "\n" stepRunnerText)
      )
    )
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

  # Path drift. The single remaining literal is compared against the manifest.
  test_secrets_nix_matches_the_manifest_root =
    assert' (secretsNixPaths == manifestPaths)
      "the machineAgeKeyPath literals in secrets.nix must be <system root>/sops/age/machine.txt for the roots services.json declares; secrets.nix=${lib.strings.concatStringsSep " | " secretsNixPaths}, manifest=${lib.strings.concatStringsSep " | " manifestPaths}";

  test_step_runner_posix_paths_match_the_manifest_root =
    assert' (stepRunnerPosixPaths == manifestPaths)
      "the POSIX roots spelled in src/scripts/lib/step-runner.ps1 must match the manifest roots; step-runner=${lib.strings.concatStringsSep " | " stepRunnerPosixPaths}, manifest=${lib.strings.concatStringsSep " | " manifestPaths}";

  # Guard against the extractor itself silently finding nothing, which would
  # make the comparison above compare [ ] with [ ] and pass.
  test_secrets_nix_path_extraction_is_not_empty =
    assert' (builtins.length secretsNixPaths == 2)
      "the secrets.nix extractor found ${toString (builtins.length secretsNixPaths)} path(s), not 2; a drift guard over two empty lists is a false green";

  # The shell side must keep deriving. Re-introducing a hardcoded platform branch
  # is the regression these two prevent, and it is silent: such a branch agrees
  # with secrets.nix until a root changes, then the two disagree invisibly.
  test_lib_sh_derives_the_root_rather_than_spelling_it =
    assert'
      (
        lib.hasInfix "nucleus_system_log_dir" (lib.concatStringsSep "\n" libShFunctionLines)
        && !lib.any (
          l: lib.hasInfix "/Library/Application Support/nucleus" l || lib.hasInfix "/var/lib/nucleus" l
        ) libShFunctionLines
      )
      "nucleus_machine_age_key_path must take the system root from nucleus_system_log_dir; a hardcoded root in its body is the duplication this replaced";

  # age_dir is still assigned, but from dirname of the shared path -- the
  # discriminator is the quote-then-slash of a literal, not the name itself.
  test_derivation_script_uses_the_shared_resolver =
    assert'
      (
        lib.hasInfix "nucleus_machine_age_key_path" deriveScriptText
        && !lib.any (l: lib.hasInfix "age_dir=\"/" l) deriveScriptLines
      )
      "derive-host-age-key.sh must build the key path from nucleus_machine_age_key_path; a literal age_dir branch is the duplication this replaced";

  # The two Windows consumers must agree on the suffix. Each must also yield
  # exactly one: an extractor that finds nothing makes the comparison below
  # compare [ ] with [ ] and pass, which is the false green this file exists
  # to prevent.
  test_windows_suffix_extraction_is_not_empty =
    assert'
      (builtins.length windowsSuffixInGetSecret == 1 && builtins.length windowsSuffixInStepRunner == 1)
      "the Windows suffix extractor found get-secret=${toString (builtins.length windowsSuffixInGetSecret)} step-runner=${toString (builtins.length windowsSuffixInStepRunner)}, not 1 each; a drift guard over two empty lists is a false green";

  test_windows_suffix_agrees_across_consumers =
    assert' (windowsSuffixInGetSecret == windowsSuffixInStepRunner)
      "the machine age key suffix must match across both PowerShell consumers; get-secret=${lib.strings.concatStringsSep " | " windowsSuffixInGetSecret}, step-runner=${lib.strings.concatStringsSep " | " windowsSuffixInStepRunner}";

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
    test_secrets_nix_matches_the_manifest_root
    test_secrets_nix_path_extraction_is_not_empty
    test_step_runner_posix_paths_match_the_manifest_root
    test_lib_sh_derives_the_root_rather_than_spelling_it
    test_derivation_script_uses_the_shared_resolver
    test_windows_suffix_extraction_is_not_empty
    test_windows_suffix_agrees_across_consumers
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  moduleCount = builtins.length posixNixFiles;
  message = "All ${toString (builtins.length allTests)} POSIX module import tests passed (${toString (builtins.length posixNixFiles)} modules, ${toString (builtins.length aggregatorImports)} imported, ${toString (builtins.length hostScopedModules)} host-scoped)";
}
