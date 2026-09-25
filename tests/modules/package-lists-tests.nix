# tests/modules/package-lists-tests.nix — Guard the centralized desired-package registry.
#
# Verifies:
#   • src/modules/packages/desired.json parses and declares every manager x host key
#   • every entry carries a well-formed name and named option fields (python/extras/pin)
#   • every "flake:<node>" pin resolves to a node in src/flake.lock
#   • every "flake:<node>" node is a github input with a revision
#   • a "flake:<node>"-pinned package has no duplicate lockfile version pin
#   • every desired package resolves to a lockfile version pin (or a flake pin)
#   • cursor.superpowers lockfile entry is valid
#   • the managed `pass` resolves to the OTP-wrapped derivation, never alongside it
#
# Run with: nix-instantiate --eval --strict tests/modules/package-lists-tests.nix

let
  inherit (import ../lib.nix) assert';

  repoRoot = ../..;
  readRepo = path: builtins.readFile (repoRoot + "/${path}");

  desired = builtins.fromJSON (readRepo "src/modules/packages/desired.json");
  lockfile = builtins.fromJSON (readRepo "src/lockfiles/lockfile.json");
  flakeLock = builtins.fromJSON (readRepo "src/flake.lock");

  managers = [
    "bun"
    "cargo-binstall"
    "pi"
    "scoop"
    "uv"
  ];
  hosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  lockfileSectionFor = manager: manager;

  entriesFor = manager: host: (desired.${manager} or { }).${host} or [ ];

  hasHostKey = manager: host: (desired.${manager} or { }) ? ${host};

  allEntries = builtins.concatMap (
    manager: builtins.concatMap (host: entriesFor manager host) hosts
  ) managers;

  entryName = entry: entry.name or "";
  entryNamesValid = builtins.all (
    entry: builtins.match "[^[:space:]]+" (entryName entry) != null
  ) allEntries;

  uvEntries = builtins.concatMap (host: entriesFor "uv" host) hosts;
  uvPythonValid = builtins.all (
    entry:
    let
      py = entry.python or null;
    in
    py == null || builtins.match "[0-9]+[.][0-9]+" py != null
  ) uvEntries;
  uvExtrasValid = builtins.all (
    entry:
    let
      ex = entry.extras or null;
    in
    ex == null || builtins.match "[a-z0-9]+(-[a-z0-9]+)*" ex != null
  ) uvEntries;

  flakePins = builtins.filter (entry: entry ? pin) uvEntries;
  flakePinNodes = builtins.map (
    entry: builtins.replaceStrings [ "flake:" ] [ "" ] entry.pin
  ) flakePins;
  flakePinsResolve = builtins.all (node: flakeLock.nodes ? ${node}) flakePinNodes;

  flakePinLocked = builtins.map (node: flakeLock.nodes.${node}.locked or { }) flakePinNodes;
  flakePinsAreGithub = builtins.all (
    locked:
    locked.type or null == "github"
    && (locked.owner or "") != ""
    && (locked.repo or "") != ""
    && (locked.rev or "") != ""
  ) flakePinLocked;
  flakePinsNotDuplicated =
    manager:
    builtins.all (
      entry: !(entry ? pin) || !((lockfile.${lockfileSectionFor manager} or { }) ? ${entryName entry})
    ) (builtins.concatMap (host: entriesFor manager host) hosts);
  noFlakePinDuplication = builtins.all flakePinsNotDuplicated managers;

  lockfilePinsResolve =
    manager:
    builtins.all (
      entry:
      (entry ? pin)
      || (
        let
          section = lockfile.${lockfileSectionFor manager} or { };
        in
        section ? ${entryName entry}
      )
    ) (builtins.concatMap (host: entriesFor manager host) hosts);

  allLockfilePinsResolve = builtins.all lockfilePinsResolve managers;

  managerHasHosts =
    manager:
    builtins.all (host: hasHostKey manager host && builtins.isList (entriesFor manager host)) hosts;
  allManagersDeclared = builtins.all (manager: desired ? ${manager}) managers;
  allHostsDeclared = builtins.all managerHasHosts managers;

  lines = text: builtins.filter builtins.isString (builtins.split "\n" text);
  hasQuotedPackageLine =
    pattern: text: builtins.any (line: builtins.match pattern line != null) (lines text);

  posixInstallers = [
    "src/scripts/packages/install-bun-packages.sh"
    "src/scripts/packages/install-pi-packages.sh"
    "src/scripts/packages/install-uv-tools.sh"
  ];
  posixInstallersFreeOfLists = builtins.all (
    path: !(hasQuotedPackageLine " *'[^']*' \\\\?" (readRepo path))
  ) posixInstallers;

  # --- Cursor superpowers lockfile (from agents-superpowers-tests.nix) ---
  hasCursor = lockfile ? cursor;
  hasSuperpowers = hasCursor && lockfile.cursor ? superpowers;
  sp = lockfile.cursor.superpowers or { };
  spSourceIsUri = (sp ? source) && builtins.match "https://.*" sp.source != null;
  spRevIsHex = (sp ? rev) && builtins.match "[0-9a-f]{40}" sp.rev != null;
  spIsValid = hasCursor && hasSuperpowers && spSourceIsUri && spRevIsHex;

  # --- Windows DSC overlap parity (from winget-overlap-parity-tests.nix) ---
  # Evaluate core.nix for one host to get the resolved package set.
  # `environment.systemPackages` is stubbed so the shared set (sharedPackages in
  # core.nix) is observable without a full host configuration.
  # WHY no `options` entry in specialArgs: specialArgs win over the module
  # system's own module arguments, so passing `options = { }` replaces core.nix's
  # options tree and silently makes its `options ? environment` guard false —
  # environment.systemPackages then stays at this stub's empty default and the
  # shared package set is unobservable.
  lib = import <nixpkgs/lib>;
  pkgsLinux = import <nixpkgs> { system = "x86_64-linux"; };
  evalCoreForHost =
    hostName:
    lib.evalModules {
      prefix = [ ];
      modules = [
        ../../src/modules/core.nix
        { nucleus.packages.selection.backend = "policy"; }
        {
          options.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            internal = true;
          };
          options.environment.systemPackages = lib.mkOption {
            # WHY nullOr: production feeds this from mkPkgs, whose overlays
            # provide pi-coding-agent and sandbox-runtime; a bare nixpkgs does
            # not, and managedNixPackages then yields null for those two entries
            # because nixPackageAttrAvailable treats a missing attribute as
            # available. Tolerating them keeps the harness free of flake
            # internals while still proving how the pass entry resolves.
            type = lib.types.listOf (lib.types.nullOr lib.types.package);
            default = [ ];
            internal = true;
          };
        }
      ];
      specialArgs = {
        lib = lib;
        pkgs = pkgsLinux;
        inherit hostName;
      };
    };
  evaluated = evalCoreForHost "Windows";
  posixEvaluated = evalCoreForHost "NixOS";
  resolvedWindowsPackages = evaluated.config.nucleus.windows.wingetPackages.packages;

  # --- Managed pass resolution (regression guard) ---
  # `pass` must land as the OTP-wrapped derivation and never alongside the plain
  # attr: two derivations providing bin/pass collide in buildEnv's paths
  # (nix-darwin's system-path keeps the first and drops the wrapper; Home
  # Manager's home-manager-path refuses to build).
  sharedPackages = posixEvaluated.config.environment.systemPackages;
  passOtpWrapper = pkgsLinux.pass.withExtensions (extensions: [ extensions.pass-otp ]);
  # WHY narrow the identity check to the pass entries: whole-set equality forces
  # `outPath` on every element, and that evaluates the meta of unrelated
  # packages, tripping check-meta's insecure refusal (dotnet-runtime-6.0.36)
  # which only the real hosts permit via mkPkgs' permittedInsecurePackages.
  passCandidates = builtins.filter (
    p: lib.hasPrefix "pass-env" (p.name or "") || lib.hasPrefix "password-store" (p.name or "")
  ) sharedPackages;
  passOtpResolved =
    lib.any (p: p.drvPath == passOtpWrapper.drvPath) passCandidates
    && !(lib.any (p: p.drvPath == pkgsLinux.pass.drvPath) passCandidates);
  committedDoc = builtins.fromJSON (readRepo "src/hosts/Windows/system/winget-packages.json");
  committedPackages = committedDoc.packages or [ ];

  wpResolvedMatchesCommitted = resolvedWindowsPackages == committedPackages;
  wpCursorDisabled = !builtins.elem "Anysphere.Cursor" resolvedWindowsPackages;
  wpObsEnabled = builtins.elem "OBSProject.OBSStudio" resolvedWindowsPackages;
  wpJdkEnabled = builtins.elem "EclipseAdoptium.Temurin.25.JDK" resolvedWindowsPackages;

  # Every DSC WinGet id must be in the generated allow-list.
  dscText = readRepo "src/hosts/Windows/system/packages.dsc.yml";
  dscLines = lib.splitString "\n" dscText;
  dscIdsRaw = builtins.filter (l: builtins.match "^        id: .*" l != null) dscLines;
  dscIds = builtins.map (l: builtins.substring 12 (builtins.stringLength l - 12) l) dscIdsRaw;
  wpDscCovered = builtins.all (
    id: builtins.elem id resolvedWindowsPackages || id == "Anysphere.Cursor"
  ) dscIds;

  # Committed JSON must be multi-line with sorted keys and single trailing newline.
  committedRaw = readRepo "src/hosts/Windows/system/winget-packages.json";
  committedBody = lib.removeSuffix "\n" committedRaw;
  wpJsonTerminated =
    builtins.match ".*\n" committedRaw != null && builtins.match ".*\n\n" committedRaw == null;
  wpJsonMultiline = builtins.match ".*\n.*" committedBody != null;
  wpJsonHasKeys = builtins.hasAttr "$schema" committedDoc && builtins.hasAttr "packages" committedDoc;

  # --- Aggregate ---
  allTestsPass =
    allManagersDeclared
    && allHostsDeclared
    && entryNamesValid
    && uvPythonValid
    && uvExtrasValid
    && flakePinsResolve
    && flakePinsAreGithub
    && noFlakePinDuplication
    && allLockfilePinsResolve
    && posixInstallersFreeOfLists
    && passOtpResolved
    && spIsValid;
in
{
  test_managers_declared = assert' allManagersDeclared "desired.json must declare every manager (${builtins.concatStringsSep ", " managers})";
  test_hosts_declared = assert' allHostsDeclared "every manager must declare every host key (${builtins.concatStringsSep ", " hosts})";
  test_entry_names_valid = assert' entryNamesValid "every entry must carry a non-empty name";
  test_uv_python_field = assert' uvPythonValid "uv 'python' must match ^[0-9]+[.][0-9]+$";
  test_uv_extras_field = assert' uvExtrasValid "uv 'extras' must match ^[a-z0-9]+(-[a-z0-9]+)*$";
  test_flake_pins_resolve = assert' flakePinsResolve "every 'flake:<node>' pin must name an existing node in src/flake.lock";
  test_flake_pins_are_github = assert' flakePinsAreGithub "every 'flake:<node>' pin must name a github input with owner, repo, and rev";
  test_flake_pins_not_duplicated = assert' noFlakePinDuplication "a 'flake:<node>'-pinned package must not also carry a lockfile version pin";
  test_lockfile_pins_resolve = assert' allLockfilePinsResolve "every desired package must have a lockfile version pin (or declare a flake pin)";
  test_no_hardcoded_posix_lists = assert' posixInstallersFreeOfLists "POSIX installers must not hardcode desired-package literals";
  test_pass_otp_resolved = assert' passOtpResolved "sharedPackages must contribute the pass-otp wrapper and not the plain pass attr";
  test_cursor_superpowers_lockfile = assert' spIsValid "cursor.superpowers must have https source and 40-char hex rev";

  # Windows DSC overlap parity tests.
  test_wp_resolved_matches_committed = assert' wpResolvedMatchesCommitted "winget-packages.json must equal the Nix-resolved Windows enable set";
  test_wp_cursor_disabled = assert' wpCursorDisabled "Cursor must be disabled on Windows";
  test_wp_obs_enabled = assert' wpObsEnabled "OBS Studio must be enabled on Windows";
  test_wp_jdk_enabled = assert' wpJdkEnabled "Temurin JDK 25 must be enabled on Windows";
  test_wp_dsc_covered = assert' wpDscCovered "Every DSC WinGet id must be in the generated allow-list";
  test_wp_json_sorted = assert' (
    wpJsonTerminated && wpJsonMultiline && wpJsonHasKeys
  ) "winget-packages.json must be multi-line with sorted keys and exactly one trailing newline";

  all_tests_pass = assert' allTestsPass "all package-lists invariants must hold";
  success = allTestsPass;
}
