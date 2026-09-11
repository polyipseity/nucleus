# tests/modules/package-lists-tests.nix — Guard the centralized desired-package registry.
#
# Verifies:
#   • src/modules/packages/desired.json parses and declares every manager x host key
#   • every entry carries a well-formed name and named option fields (python/extras/pin)
#   • every "flake:<node>" pin resolves to a node in src/flake.lock
#   • every "flake:<node>" node is a github input with a revision
#   • a "flake:<node>"-pinned package has no duplicate lockfile version pin
#   • every desired package resolves to a lockfile version pin (or a flake pin)
#   • the POSIX and Windows consumers read the shared registry instead of
#     carrying their own hardcoded lists
#
# Run with: nix-instantiate --eval --strict tests/modules/package-lists-tests.nix

let
  inherit (import ../lib.nix) assert' flatten containsRegex;

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

  # Lockfile section that pins each manager's packages.
  lockfileSectionFor = manager: manager;

  entriesFor = manager: host: (desired.${manager} or { }).${host} or [ ];

  # Explicit key-presence check: entriesFor defaults to [ ] so a missing host
  # key cannot masquerade as an intentionally empty list.
  hasHostKey = manager: host: (desired.${manager} or { }) ? ${host};

  # concatMap flattens one level per nesting, so the entry sets come out flat.
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

  # A flake-pinned tool is installed from a git revision, so the node must be a
  # github input carrying a revision: Windows derives
  # 'https://github.com/<owner>/<repo>' + rev from it (Invoke-UvSetup) and the
  # enforcement probe compares that rev against the installed commit.  The tool
  # must not also carry a lockfile pin: the flake revision is the single source.
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

  # Section with a single host keyed list, for the consumers below.
  managerHasHosts =
    manager:
    builtins.all (host: hasHostKey manager host && builtins.isList (entriesFor manager host)) hosts;
  allManagersDeclared = builtins.all (manager: desired ? ${manager}) managers;
  allHostsDeclared = builtins.all managerHasHosts managers;

  # --- Consumers must read the shared registry ------------------------------
  posixModuleReads = containsRegex "packages/desired[.]json" (readRepo "src/modules/agents.nix");
  windowsConsumers = [
    "src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1"
    "src/platforms/Windows/modules/setup/Invoke-CargoBinstallSetup.ps1"
    "src/platforms/Windows/modules/setup/Invoke-ScoopSetup.ps1"
    "src/platforms/Windows/modules/setup/Invoke-UvSetup.ps1"
  ];
  windowsConsumersRead = builtins.all (
    path: containsRegex "desired[.]json" (readRepo path)
  ) windowsConsumers;

  # Hardcoded per-package lines look like:  'pkg-name' \
  # Comments never start with a quote, so this only catches list literals.
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

  # --- Aggregate ------------------------------------------------------------
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
    && posixModuleReads
    && windowsConsumersRead
    && posixInstallersFreeOfLists;
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
  test_posix_module_reads_registry = assert' posixModuleReads "src/modules/agents.nix must read src/modules/packages/desired.json";
  test_windows_consumers_read_registry = assert' windowsConsumersRead "every Windows setup consumer must read desired.json";
  test_no_hardcoded_posix_lists = assert' posixInstallersFreeOfLists "POSIX installers must not hardcode desired-package literals";

  all_tests_pass = assert' allTestsPass "all package-lists invariants must hold";
  success = allTestsPass;
}
