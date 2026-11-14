# tests/modules/package-lists-tests.nix: Guard the centralized desired-package registry.
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
#   • the Stirling-PDF entry resolves enabled on every host and deploys the desktop build
#   • Windows DSC package ids are sorted alphabetically (case-folded)
#   • winget-packages.json is $schema-first at the root key level
#   • the ScoopInstall DSC bootstrap guard: block-anchored id and dependsOn pairing, enable-list coverage, and the DSC/WinGet parity aggregate members.
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
  # options tree and silently makes its `options ? environment` guard false,
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
            type = lib.types.listOf lib.types.package;
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
  # --- Stirling-PDF desktop resolution ---
  # The registry must carry the entry and deploy the Tauri desktop build.
  # WHY pname: `nixpkgsPackage` is what lands in the package set, so the
  # derivation name is the only observable that separates the desktop build from
  # the headless server attr the entry probes.
  # WHY no per-host presence claim: `nucleus.packages.enabled` carries a key for
  # every managedPackages entry on every host, so presence is all-or-nothing.
  # This suite asserts existence and the Linux derivation only; which carrier
  # (Homebrew cask, nixpkgs attr, WinGet id) resolves on which host is not
  # asserted here, so a green run does not prove per-host availability.
  stirlingHostNames = [
    "MacBook"
    "NixOS"
    "Windows"
  ];
  stirlingEvaluations = builtins.map (host: {
    inherit host;
    enabled = (evalCoreForHost host).config.nucleus.packages.enabled;
  }) stirlingHostNames;
  stirlingRegistryPresent = builtins.all (e: e.enabled ? "stirling-pdf") stirlingEvaluations;
  stirlingDisabledHosts = builtins.filter (
    e: (e.enabled ? "stirling-pdf") && !e.enabled."stirling-pdf"
  ) stirlingEvaluations;
  stirlingNixPnames = builtins.map (p: p.pname or "") (
    builtins.filter (p: lib.hasPrefix "stirling-pdf" (p.pname or "")) sharedPackages
  );
  stirlingDesktopResolved = stirlingNixPnames == [ "stirling-pdf-desktop" ];

  committedDoc = builtins.fromJSON (readRepo "src/hosts/Windows/system/winget-packages.json");
  committedPackages = committedDoc.packages or [ ];

  wpResolvedMatchesCommitted = resolvedWindowsPackages == committedPackages;
  wpCursorDisabled = !builtins.elem "Anysphere.Cursor" resolvedWindowsPackages;
  wpObsEnabled = builtins.elem "OBSProject.OBSStudio" resolvedWindowsPackages;
  wpJdkEnabled = builtins.elem "EclipseAdoptium.Temurin.25.JDK" resolvedWindowsPackages;

  # Enabled WinGet ids must each carry a lockfile version pin. The exception
  # list holds the ids microsoft/winget-pkgs does not serve, so the updater
  # cannot pin them: the msstore id, verified on Windows with
  # `winget show <id> --source msstore`.
  wingetPinExceptions = [
    "9NBDXK71NK08"
  ];
  wingetMissingPins = builtins.filter (
    id: !(builtins.elem id wingetPinExceptions || lockfile.winget ? ${id})
  ) resolvedWindowsPackages;
  wingetPinsResolve = wingetMissingPins == [ ];

  # WHY: a desired package with `bucket: "nucleus"` installs from
  # src/modules/scoop-manifests/<name>.json, so an entry without that manifest
  # fails the Windows apply with a manifest-not-found error instead of
  # converging. The check is existence only; scoop-manifest-hashes-tests owns
  # the content of the manifests that do exist.
  nucleusScoopNames = builtins.map (entry: entry.name) (
    builtins.filter (entry: (entry.bucket or null) == "nucleus") (entriesFor "scoop" "Windows")
  );
  hasNucleusScoopManifest =
    name: builtins.pathExists (repoRoot + "/src/modules/scoop-manifests/${name}.json");
  missingNucleusScoopManifests = builtins.filter (
    name: !(hasNucleusScoopManifest name)
  ) nucleusScoopNames;
  nucleusScoopManifestsPresent = missingNucleusScoopManifests == [ ];

  # WHY: `nucleus/<name>@<pin>` names the exact version Scoop installs, while a
  # manifest serves exactly one version, so a one-sided bump installs nothing.
  # An entry with no manifest is skipped here because the existence test owns it.
  scoopVersionText = value: if value == null then "<missing>" else toString value;
  nucleusScoopPins =
    builtins.map
      (
        entry:
        let
          name = entry.name;
        in
        {
          inherit name;
          pinned = lockfile.scoop.${name} or null;
          manifestVersion =
            (builtins.fromJSON (readRepo "src/modules/scoop-manifests/${name}.json")).version or null;
        }
      )
      (
        builtins.filter (entry: (entry.bucket or null) == "nucleus" && hasNucleusScoopManifest entry.name) (
          entriesFor "scoop" "Windows"
        )
      );
  nucleusScoopVersionMismatches = builtins.map (
    entry:
    "${entry.name}: lockfile scoop pin ${scoopVersionText entry.pinned}, manifest version ${scoopVersionText entry.manifestVersion}"
  ) (builtins.filter (entry: entry.pinned != entry.manifestVersion) nucleusScoopPins);
  nucleusScoopVersionPinsMatch = nucleusScoopVersionMismatches == [ ];

  deepFilterDesiredPresent = lib.any (
    entry: entry.name == "deep-filter" && (entry.bucket or null) == "nucleus"
  ) (entriesFor "scoop" "Windows");

  # Every DSC WinGet id must be in the generated allow-list.
  dscText = readRepo "src/hosts/Windows/system/packages.dsc.yml";
  dscLines = lib.splitString "\n" dscText;
  dscIdsRaw = builtins.filter (l: builtins.match "^        id: .*" l != null) dscLines;
  dscIds = builtins.map (l: builtins.substring 12 (builtins.stringLength l - 12) l) dscIdsRaw;
  wpDscCovered = builtins.all (
    id: builtins.elem id resolvedWindowsPackages || id == "Anysphere.Cursor"
  ) dscIds;

  # The Scoop bootstrap is a Script resource, so its id sits at the resource
  # level and the settings.id scan above cannot see it. WHY split on resource
  # markers: the id and its dependsOn must appear in the same DSC resource
  # block, so a dependency moved under any other block fails instead of passing
  # on a wider scan.
  scoopScriptBlock =
    let
      entries = lib.splitString "\n    - resource: " dscText;
    in
    lib.findFirst (entry: lib.hasInfix "\n      id: ScoopInstall\n" entry) null entries;
  wpScoopInstallPresent =
    scoopScriptBlock != null && lib.hasInfix "\n        - GitInstall\n" scoopScriptBlock;

  # The enable list and the DSC file are two halves of one deployment: the list
  # decides which ids the updater pins, the DSC file decides which of them an
  # apply installs. An id in the first without a resource in the second is
  # pinned and never installed. WHY one exception: the WinGet SteamCMD package
  # installs outside the steamcmd_install_path RimSort reads, so
  # Invoke-SteamCMDSetup.ps1 provisions the binary from Valve's CDN instead of a
  # DSC resource (POSIX twin: src/scripts/configs/provision-steamcmd.sh).
  # ref: allow-and-deny-lists.instructions.md#D8 -- tier 2, so the staleness
  #   guard below fails an exception that no longer holds.
  wingetDscExceptions = [ "Valve.SteamCMD" ];
  wingetMissingDscResources = builtins.filter (
    id: !(builtins.elem id dscIds) && !(builtins.elem id wingetDscExceptions)
  ) resolvedWindowsPackages;
  wpDscCoversEnableList = wingetMissingDscResources == [ ];
  # An exception is stale when the id stopped being enabled (the exception now
  # protects nothing) or when the id gained a DSC resource (the exception now
  # hides a real gap). Both must fail rather than linger.
  wingetStaleDscExceptions = builtins.filter (
    id: !(builtins.elem id resolvedWindowsPackages) || builtins.elem id dscIds
  ) wingetDscExceptions;
  wpDscExceptionsFresh = wingetStaleDscExceptions == [ ];

  # The package group is sorted alphabetically by `settings.id`
  # (`.agents/instructions/winget-dsc.instructions.md`, "Resource groups and
  # ordering"). WHY case-folded: WinGet ids keep their own casing, so ids such as
  # `astral-sh.uv`, `ajeetdsouza.zoxide`, and `chrisant996.Clink` sit among
  # `BlenderFoundation.Blender` and `CaddyServer.Caddy`; a byte
  # comparison would instead move every lowercase-leading id past every
  # uppercase-leading one.
  dscSortKey = id: lib.toLower id;
  dscSortedIds = builtins.sort (a: b: dscSortKey a < dscSortKey b) dscIds;
  dscSorted = dscIds != [ ] && dscIds == dscSortedIds;
  # WHY report adjacent inversions: each names one misplaced block, while a
  # position-by-position diff would also list every id that a single insert
  # displaces.
  dscInversions = lib.filter (pair: dscSortKey pair.fst > dscSortKey pair.snd) (
    if dscIds == [ ] then [ ] else lib.zipLists dscIds (builtins.tail dscIds)
  );

  # Committed JSON must be multi-line with sorted keys and single trailing newline.
  committedRaw = readRepo "src/hosts/Windows/system/winget-packages.json";
  committedBody = lib.removeSuffix "\n" committedRaw;
  wpJsonTerminated =
    builtins.match ".*\n" committedRaw != null && builtins.match ".*\n\n" committedRaw == null;
  wpJsonMultiline = builtins.match ".*\n.*" committedBody != null;
  wpJsonHasKeys = builtins.hasAttr "$schema" committedDoc && builtins.hasAttr "packages" committedDoc;
  # WHY: check step 03 compares this file byte for byte against its derivation
  # and key order is part of that comparison, so a reshaped document that still
  # parses must fail here too, on every host, not only where step 03 can build
  # the artifact. Root keys sit at a two-space indent and nested keys sit
  # deeper, so the pattern below selects the root level only.
  wpJsonKeyOrder =
    let
      keyLines = builtins.filter (l: builtins.match "  \"[^\"]+\":.*" l != null) (
        lib.splitString "\n" committedRaw
      );
    in
    keyLines != [ ] && builtins.match "  \"\\$schema\":.*" (builtins.head keyLines) != null;

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
    && wingetPinsResolve
    && nucleusScoopManifestsPresent
    && nucleusScoopVersionPinsMatch
    && deepFilterDesiredPresent
    && posixInstallersFreeOfLists
    && passOtpResolved
    && stirlingRegistryPresent
    && stirlingDisabledHosts == [ ]
    && stirlingDesktopResolved
    && spIsValid
    && wpDscCoversEnableList
    && wpDscExceptionsFresh
    && wpScoopInstallPresent
    && wpResolvedMatchesCommitted
    && wpCursorDisabled
    && wpObsEnabled
    && wpJdkEnabled
    && wpDscCovered
    && dscSorted
    && wpJsonTerminated
    && wpJsonMultiline
    && wpJsonHasKeys
    && wpJsonKeyOrder;
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
  test_winget_lockfile_pins_resolve = assert' wingetPinsResolve "enabled WinGet ids missing a lockfile pin: ${builtins.concatStringsSep ", " wingetMissingPins}";
  test_nucleus_scoop_manifests_present = assert' nucleusScoopManifestsPresent "bucket 'nucleus' entries missing a src/modules/scoop-manifests manifest: ${builtins.concatStringsSep ", " missingNucleusScoopManifests}";
  test_nucleus_scoop_version_pins_match = assert' nucleusScoopVersionPinsMatch "nucleus Scoop lockfile pins must match their manifest versions: ${builtins.concatStringsSep ", " nucleusScoopVersionMismatches}";
  test_deep_filter_scoop_desired = assert' deepFilterDesiredPresent "deep-filter must be a nucleus-bucket Scoop entry in desired.json scoop.Windows";
  test_no_hardcoded_posix_lists = assert' posixInstallersFreeOfLists "POSIX installers must not hardcode desired-package literals";
  test_pass_otp_resolved = assert' passOtpResolved "sharedPackages must contribute the pass-otp wrapper and not the plain pass attr";
  test_stirling_pdf_registry_present = assert' stirlingRegistryPresent "the stirling-pdf entry must exist in managedPackages";
  test_stirling_pdf_enabled_everywhere =
    assert' (stirlingDisabledHosts == [ ])
      "the stirling-pdf registry entry must be enabled on every host; disabled on: ${
        builtins.concatStringsSep ", " (builtins.map (e: e.host) stirlingDisabledHosts)
      }";
  test_stirling_pdf_desktop_resolved = assert' stirlingDesktopResolved "the registry must contribute exactly the stirling-pdf-desktop derivation; resolved: ${
    builtins.concatStringsSep ", " (
      if stirlingNixPnames == [ ] then [ "<none>" ] else stirlingNixPnames
    )
  }";
  test_cursor_superpowers_lockfile = assert' spIsValid "cursor.superpowers must have https source and 40-char hex rev";

  # Windows DSC overlap parity tests.
  test_wp_resolved_matches_committed = assert' wpResolvedMatchesCommitted "winget-packages.json must equal the Nix-resolved Windows enable set";
  test_wp_cursor_disabled = assert' wpCursorDisabled "Cursor must be disabled on Windows";
  test_wp_obs_enabled = assert' wpObsEnabled "OBS Studio must be enabled on Windows";
  test_wp_jdk_enabled = assert' wpJdkEnabled "Temurin JDK 25 must be enabled on Windows";
  test_wp_dsc_covered = assert' wpDscCovered "Every DSC WinGet id must be in the generated allow-list";
  test_wp_dsc_sorted = assert' dscSorted "DSC package ids must be sorted alphabetically (case-folded): ${
    builtins.concatStringsSep ", " (builtins.map (pair: "${pair.fst} before ${pair.snd}") dscInversions)
  }";
  test_wp_scoop_install_present = assert' wpScoopInstallPresent "the DSC file must keep the six-space id: ScoopInstall block with its GitInstall dependency";
  test_wp_dsc_covers_enable_list = assert' wpDscCoversEnableList "enabled WinGet ids with no DSC resource: ${builtins.concatStringsSep ", " wingetMissingDscResources}";
  test_wp_dsc_exceptions_fresh = assert' wpDscExceptionsFresh "stale WinGet DSC exceptions (no longer enabled, or now carrying a DSC resource): ${builtins.concatStringsSep ", " wingetStaleDscExceptions}";
  test_wp_json_sorted = assert' (
    wpJsonTerminated && wpJsonMultiline && wpJsonHasKeys
  ) "winget-packages.json must be multi-line with sorted keys and exactly one trailing newline";
  test_wp_json_key_order = assert' wpJsonKeyOrder "$schema must be the first root key in winget-packages.json";

  all_tests_pass = assert' allTestsPass "all package-lists invariants must hold";
  success = allTestsPass;
}
