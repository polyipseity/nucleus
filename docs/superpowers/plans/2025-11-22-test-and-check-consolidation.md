# Test & Check Consolidation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove dead/trivial grep-only tests, consolidate fragmented test files, and convert high-value grep-based tests to behavioral tests that validate behavior rather than implementation text.

**Architecture:** The repo has ~49 Nix test files, ~27 Pester files, ~50 shell/PS test files, and 19 check steps. The dominant anti-pattern is `containsRegex` / `lib.hasInfix` / `grep` assertions against `builtins.readFile` source text — these test that specific strings exist in source files, not that behavior is correct. When implementation text changes (reflow, rename, restructure), these tests break even though behavior is preserved.

**Tech Stack:** Nix (`nix-instantiate --eval`), Pester (PowerShell), Bash (`test-lib.sh`), step-runner framework

**Spec:** `.agents/instructions/testing.instructions.md`

## Global Constraints

- Tests must use `builtins.seq (builtins.deepSeq ... null)` or equivalent to force evaluation
- No real-user test coupling — use `tests/fixtures/user-registry/` only
- POSIX tests use `test-lib.sh`; Windows tests use Pester
- Check steps run via step-runner with wave parallelism
- `testing.instructions.md` conventions are authoritative

---

## Audit Summary

### What was found

| Category | Count | Classification |
|----------|-------|---------------|
| Check steps (01–19) | 19 steps | **All KEEP** — every step validates a real invariant |
| Nix module tests | 30 files | 12 KEEP, 8 FIX, 4 CONSOLIDATE, 6 REMOVE |
| Nix integration tests | 9 files | 4 KEEP, 4 FIX, 1 REMOVE |
| Nix host tests | 7 files | 3 KEEP, 1 FIX, 3 REMOVE |
| Nix platform tests | 2 files | 1 KEEP, 1 FIX |
| Script-level tests | ~50 files | ~45 KEEP, ~5 REMOVE |
| Pester tests | 27 files | **All KEEP** — well-structured behavioral tests |
| Test infrastructure | 4 files | **All KEEP** |

### The dominant anti-pattern

~25 test files use `builtins.readFile ../../src/...` followed by `containsRegex` / `lib.hasInfix` to check that specific text strings exist in source files. These are **implementation-coupled regression guards** — they verify text, not behavior. They break on code reflow, variable renaming, or comment changes while providing zero behavioral assurance.

---

## Phase 1: Remove Dead/Trivial Tests (10 files)

Safe deletions. These tests provide zero or near-zero behavioral value.

### Task 1.1: Remove empty/no-op test

- [ ] **Step 1: Delete `tests/modules/macos-homebrew-exclusion-tests.nix`**

  This file has a detailed comment describing what it SHOULD test, but the body is `{ success = true; message = "..."; }` — zero assertions. It's a no-op.

  ```bash
  rm tests/modules/macos-homebrew-exclusion-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove empty macos-homebrew-exclusion-tests.nix"
  ```

### Task 1.2: Remove mock-only test

- [ ] **Step 1: Delete `tests/modules/sops-mock-tests.nix`**

  252 lines testing a hardcoded mock SOPS config that has no connection to the real `.sops.yaml` or real secrets. The mock structure drifts from reality and provides no behavioral value.

  ```bash
  rm tests/modules/sops-mock-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove sops-mock-tests.nix (tests mock, not real config)"
  ```

### Task 1.3: Remove grep-only integration test

- [ ] **Step 1: Delete `tests/integration/config-composition-tests.nix`**

  17 grep assertions checking that import paths like `"../../modules/core.nix"` exist in source files. These are pure implementation coupling — `nix flake check` already validates that all imports resolve. If an import breaks, the build fails. These grep tests add nothing.

  ```bash
  rm tests/integration/config-composition-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/integration/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove config-composition-tests.nix (grep for import paths)"
  ```

### Task 1.4: Remove grep-only host tests

- [ ] **Step 1: Delete these 3 files**

  Each has 2–8 grep assertions checking shell escaping or script text. If escaping breaks, `nix flake check` or activation fails at runtime. These are trivial regression guards with no behavioral value.

  ```bash
  rm tests/hosts/MacBook/activation-escaping-tests.nix
  rm tests/hosts/MacBook/linux-builder-escaping-tests.nix
  rm tests/hosts/MacBook/command-line-tools-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/hosts/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove trivial grep-only host tests (escaping, CLT)"
  ```

### Task 1.5: Remove grep-only module tests

- [ ] **Step 1: Delete these 3 files**

  - `tests/modules/repo-root-recording-tests.nix` (21 lines, 6 grep assertions checking `apply.sh` and `lib.sh` text)
  - `tests/modules/user-config-placement-tests.nix` (44 lines, 16 grep assertions checking function name presence across 9 source files)
  - `tests/modules/obs-virtual-camera-tests.nix` (34 lines, 3 grep assertions against `desktop.nix`)

  ```bash
  rm tests/modules/repo-root-recording-tests.nix
  rm tests/modules/user-config-placement-tests.nix
  rm tests/modules/obs-virtual-camera-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove grep-only module tests (repo-root, config-placement, obs-virtual-cam)"
  ```

### Task 1.6: Remove trivial cloud-mount-paths test

- [ ] **Step 1: Delete `tests/modules/cloud-mount-paths-tests.nix`**

  20 lines, single grep assertion checking for an error message string. Will be consolidated into cloud-drive tests in Phase 2.

  ```bash
  rm tests/modules/cloud-mount-paths-tests.nix
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/ 2>&1 | tail -5
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove cloud-mount-paths-tests.nix (single grep assertion)"
  ```

---

## Phase 2: Consolidate Fragmented Tests (3 merges)

Merge related small test files into cohesive suites.

### Task 2.1: Merge cloud-launchd-agents + cloud-mount-paths → cloud-drive-tests.nix

- [ ] **Step 1: Read existing files**

  Read `tests/modules/cloud-launchd-agents-tests.nix` (46 lines). The deleted `cloud-mount-paths-tests.nix` had one assertion — fold its invariant into the new file.

- [ ] **Step 2: Create `tests/modules/cloud-drive-tests.nix`**

  ```nix
  # tests/modules/cloud-drive-tests.nix — Cloud drive launchd agents and mount paths.

  let
    inherit (import ../lib.nix) assert' containsRegex;

    cloudDrivesText = builtins.readFile ../../src/modules/cloud-drives.nix;

    # Cloud launchd agents must declare both label and program-arguments.
    test_cloud_agents_declare_required_keys = assert' (
      containsRegex "Label" cloudDrivesText
      && containsRegex "ProgramArguments" cloudDrivesText
    ) "Cloud drive launchd agents must declare Label and ProgramArguments";

    # Cloud mount paths must not use symlink-based mounts (must use bind mounts or similar).
    test_cloud_mount_paths_no_symlink = assert' (
      !(containsRegex "symlink.*mount" cloudDrivesText)
    ) "Cloud mount paths must not use symlink-based mounts";

    allTests = [
      test_cloud_agents_declare_required_keys
      test_cloud_mount_paths_no_symlink
    ];
  in
  builtins.seq (builtins.deepSeq allTests null) {
    success = true;
    testCount = builtins.length allTests;
    message = "All ${toString (builtins.length allTests)} cloud drive tests passed";
  }
  ```

  Note: The above is a skeleton. The actual file should preserve the existing assertions from `cloud-launchd-agents-tests.nix` and add the mount-path invariant. Read the original file first and adapt its assertions.

- [ ] **Step 3: Delete `tests/modules/cloud-launchd-agents-tests.nix`**

  ```bash
  rm tests/modules/cloud-launchd-agents-tests.nix
  ```

- [ ] **Step 4: Verify test suite passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/cloud-drive-tests.nix
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add -A && git commit -m "test: consolidate cloud drive tests into cloud-drive-tests.nix"
  ```

### Task 2.2: Merge host redis-service-tests into parity file

- [ ] **Step 1: Read both files**

  Read `tests/hosts/MacBook/redis-service-tests.nix` and `tests/hosts/Windows/redis-service-tests.nix`.

- [ ] **Step 2: Create `tests/hosts/redis-parity-tests.nix`**

  Combine both into a single file that validates Redis configuration parity across hosts. Keep the behavioral assertions (services.json structure, loopback binding, port, SOPS password wiring). Remove grep-only assertions.

- [ ] **Step 3: Delete both original files**

  ```bash
  rm tests/hosts/MacBook/redis-service-tests.nix tests/hosts/Windows/redis-service-tests.nix
  ```

- [ ] **Step 4: Verify test suite passes**

  ```bash
  cd src && nix-instantiate --eval --strict tests/hosts/redis-parity-tests.nix
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add -A && git commit -m "test: consolidate Redis service tests into cross-host parity file"
  ```

### Task 2.3: Merge launchd-user-agent + cloud-launchd tests

- [ ] **Step 1: Read `tests/modules/launchd-user-agent-tests.nix`**

  This tests launchd user-agent unification policy. After Task 2.1 renames cloud-launchd-agents, verify no overlap.

- [ ] **Step 2: If overlap exists, consolidate into `tests/modules/launchd-policy-tests.nix`**

  Merge the launchd user-agent unification assertions with any cloud-specific launchd assertions. Remove pure grep assertions; keep behavioral ones.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/ 2>&1 | tail -5
  git add -A && git commit -m "test: consolidate launchd policy tests"
  ```

---

## Phase 3: Convert High-Value Grep Tests to Behavioral (5 files)

These tests have real invariants worth preserving, but their grep-based approach is fragile. Convert to behavioral tests that evaluate Nix modules with fixture data.

### Task 3.1: Convert `tests/modules/symlinks-tests.nix`

- [ ] **Step 1: Read the current file**

  66 lines. All 5 tests use `builtins.readFile` + `containsRegex` against `home.nix`, `symlinks.nix`, `activation-dag.nix`, and Windows scripts.

- [ ] **Step 2: Rewrite with behavioral assertions**

  Instead of checking text patterns, import the symlinks module with fixture data and verify the output attributes:

  ```nix
  # tests/modules/symlinks-tests.nix — Per-user symlink wiring (behavioral).

  let
    fixtures = import ../fixtures { };
    inherit (fixtures) fixtureUsername loadFixtureRegistry;

    inherit (import ../lib.nix) assert';

    # Load the actual symlinks module output with fixture data.
    usersMacBook = loadFixtureRegistry "MacBook";
    usersWindows = loadFixtureRegistry "Windows";

    # Behavioral: test-user must have symlinks configured on both platforms.
    test_user_has_symlinks_macbook = assert' (
      (usersMacBook.${fixtureUsername}.symlinks or []) != []
    ) "test-user must have symlinks on MacBook";

    test_user_has_symlinks_windows = assert' (
      (usersWindows.${fixtureUsername}.symlinks or []) != []
    ) "test-user must have symlinks on Windows";

    # Behavioral: symlinks must have path and per-host targets.
    test_symlink_structure = assert' (
      let first = builtins.head usersMacBook.${fixtureUsername}.symlinks;
      in first ? path && first ? MacBook && first ? NixOS && first ? Windows
    ) "Each symlink entry must have path and per-host targets";

    allTests = [
      test_user_has_symlinks_macbook
      test_user_has_symlinks_windows
      test_symlink_structure
    ];
  in
  builtins.seq (builtins.deepSeq allTests null) {
    success = true;
    testCount = builtins.length allTests;
    message = "All ${toString (builtins.length allTests)} symlinks tests passed";
  }
  ```

  Note: Adapt based on the actual module structure. The key principle is to evaluate the module, not read its source text.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/symlinks-tests.nix
  git add -A && git commit -m "test: convert symlinks-tests.nix from grep to behavioral"
  ```

### Task 3.2: Convert `tests/modules/treefmt-tests.nix`

- [ ] **Step 1: Read the current file**

  65 lines. All 4 tests use `lib.hasInfix` against `treefmt.nix` and `core.nix` text.

- [ ] **Step 2: Rewrite with behavioral assertions**

  Import the treefmt configuration and verify the evaluation produces expected formatter configs:

  ```nix
  # tests/modules/treefmt-tests.nix — treefmt formatter enablement (behavioral).

  let
    lib = import <nixpkgs/lib>;
    inherit (import ../lib.nix) assert';

    # Import the actual treefmt config and verify formatters are enabled.
    treefmtConfig = import ../../src/treefmt.nix;

    # Behavioral: verify the treefmt evaluation produces expected formatter entries.
    test_shfmt_enabled = assert' (
      treefmtConfig ? programs && treefmtConfig.programs ? shfmt
    ) "treefmt must enable shfmt formatter";

    test_taplo_enabled = assert' (
      treefmtConfig.programs ? taplo
    ) "treefmt must enable taplo formatter";

    # ... etc for each formatter

    allTests = [ test_shfmt_enabled test_taplo_enabled ];
  in
  builtins.seq (builtins.deepSeq allTests null) {
    success = true;
    testCount = builtins.length allTests;
    message = "All ${toString (builtins.length allTests)} treefmt tests passed";
  }
  ```

  Note: The actual rewrite depends on how `treefmt.nix` is structured. If it's a module that requires `config` arguments, use `lib.evalModules` or test the flake's treefmt overlay instead.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/treefmt-tests.nix
  git add -A && git commit -m "test: convert treefmt-tests.nix from grep to behavioral"
  ```

### Task 3.3: Convert `tests/integration/svc-tests.nix`

- [ ] **Step 1: Read the current file**

  261 lines. Almost entirely grep: checks function names, subcommand presence, column format in script text.

- [ ] **Step 2: Rewrite structural assertions as data-driven tests**

  Parse `services.json` with `builtins.fromJSON` and validate the data structure directly:

  ```nix
  # tests/integration/svc-tests.nix — Service management (behavioral).

  let
    lib = import <nixpkgs/lib>;
    inherit (import ../lib.nix) assert';

    servicesJson = builtins.fromJSON (builtins.readFile ../../src/services.json);

    # Behavioral: every service must have required fields.
    test_all_services_have_name = assert' (
      lib.all (svc: svc ? name) (builtins.attrValues servicesJson)
    ) "Every service must have a name field";

    test_all_services_have_type = assert' (
      lib.all (svc: svc ? type) (builtins.attrValues servicesJson)
    ) "Every service must have a type field";

    # Behavioral: no service references invalid hosts.
    validHosts = [ "MacBook" "NixOS" "Windows" ];
    test_all_hosts_valid = assert' (
      lib.all (svc:
        !(svc ? hosts) || lib.all (h: builtins.elem h validHosts) svc.hosts
      ) (builtins.attrValues servicesJson)
    ) "All service host references must be valid";

    allTests = [
      test_all_services_have_name
      test_all_services_have_type
      test_all_hosts_valid
    ];
  in
  builtins.seq (builtins.deepSeq allTests null) {
    success = true;
    testCount = builtins.length allTests;
    message = "All ${toString (builtins.length allTests)} service tests passed";
  }
  ```

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/integration/svc-tests.nix
  git add -A && git commit -m "test: convert svc-tests.nix from grep to data-driven"
  ```

### Task 3.4: Convert `tests/integration/service-watchdog-tests.nix`

- [ ] **Step 1: Read the current file**

  100 lines. 100% grep: checks script content, services.json patterns, launchd/systemd config.

- [ ] **Step 2: Rewrite as data-driven tests**

  Parse `services.json` and validate watchdog-related fields structurally. Remove all `builtins.readFile` + `containsRegex` patterns.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/integration/service-watchdog-tests.nix
  git add -A && git commit -m "test: convert service-watchdog-tests.nix from grep to data-driven"
  ```

### Task 3.5: Convert `tests/integration/menu-bar-tests.nix`

- [ ] **Step 1: Read the current file**

  181 lines. Almost entirely grep: checks `apps.json` text patterns, script function names.

- [ ] **Step 2: Rewrite as data-driven tests**

  Parse `apps.json` with `builtins.fromJSON` and validate the menu bar registry structurally:
  - Every app with `menuBarIcon: true` has a valid `icon` field
  - Every app has at least one host entry
  - No duplicate app names

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/integration/menu-bar-tests.nix
  git add -A && git commit -m "test: convert menu-bar-tests.nix from grep to data-driven"
  ```

---

## Phase 4: Fix Tests with Wrong Approach (4 files)

These tests have valuable invariants but test the wrong thing. Fix the approach without removing the test.

### Task 4.1: Fix `tests/modules/core-tests.nix`

- [ ] **Step 1: Read the current file**

  Identify which assertions are pure-logic (backend selection, override precedence) — **keep those**. Identify nix-index timer grep assertions — **remove those** (they test text, not timer behavior).

- [ ] **Step 2: Remove grep assertions, keep behavioral ones**

  Delete the `builtins.readFile` + `containsRegex` blocks that check `core.nix` text. Keep the pure-logic tests that validate option defaults, conditional logic, and list operations.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/modules/core-tests.nix
  git add -A && git commit -m "test: fix core-tests.nix — remove grep assertions, keep behavioral"
  ```

### Task 4.2: Fix `tests/hosts/MacBook/ntfs-3g-build-tests.nix`

- [ ] **Step 1: Read the current file**

  59 lines, ~12 grep assertions checking build script and nix file text.

- [ ] **Step 2: Convert to derivation evaluation test**

  Instead of grepping text, verify the NTFS-3G build derivation evaluates successfully:

  ```nix
  # Verify the ntfs-3g derivation evaluates without error.
  test_ntfs3g_derivation_evaluates = assert' (
    let
      pkgs = import <nixpkgs> { };
      # Import the actual ntfs-3g build and verify it has expected outputs.
    in true  # Adapt to actual module structure
  ) "ntfs-3g derivation must evaluate successfully";
  ```

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/hosts/MacBook/ntfs-3g-build-tests.nix
  git add -A && git commit -m "test: fix ntfs-3g-build-tests.nix — convert grep to derivation eval"
  ```

### Task 4.3: Fix `tests/integration/activation-deps-tests.nix`

- [ ] **Step 1: Read the current file**

  Mix of mock-data ordering tests (good) and grep assertions (bad). ~60% grep.

- [ ] **Step 2: Keep mock-data tests, remove grep assertions**

  The mock-data ordering tests validate activation dependency logic — keep them. Remove the `builtins.readFile` + `containsRegex` blocks that check source file text.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/integration/activation-deps-tests.nix
  git add -A && git commit -m "test: fix activation-deps-tests.nix — remove grep, keep mock-data tests"
  ```

### Task 4.4: Fix `tests/hosts/MacBook/passwords-defaults-tests.nix`

- [ ] **Step 1: Read the current file**

  Grep regression guard checking text patterns across multiple files for PassKit.policy migration.

- [ ] **Step 2: Convert to data-driven validation**

  Instead of grepping for specific text patterns, verify the PassKit policy structure by reading the actual policy file as data and validating its fields.

- [ ] **Step 3: Verify and commit**

  ```bash
  cd src && nix-instantiate --eval --strict tests/hosts/MacBook/passwords-defaults-tests.nix
  git add -A && git commit -m "test: fix passwords-defaults-tests.nix — convert grep to data-driven"
  ```

---

## Phase 5: Remove Low-Value Script Tests (3 files)

### Task 5.1: Remove `tests/scripts/nucleus-apps-smoke-tests.sh`

- [ ] **Step 1: Delete the file**

  This smoke-tests nucleus-* commands by building and running `--help`. This is already covered by check step 10 (completions-fresh) which verifies completions and `--list-*` flags. The smoke test adds marginal value at high CI cost (full Nix build per command).

  ```bash
  rm tests/scripts/nucleus-apps-smoke-tests.sh
  ```

- [ ] **Step 2: Verify test suite still passes**

  ```bash
  nix run ./src#test -- --skip-steps=nix-tests,system-config-build
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "test: remove nucleus-apps-smoke-tests.sh (covered by step 10)"
  ```

### Task 5.2: Audit `tests/scripts/apply-dispatch-tests.sh`

- [ ] **Step 1: Read the file**

  Check if the grep assertions (e.g., `grep -Fq '#MacBook'`) are testing behavior or just text. If it's checking that `apply.sh` references PascalCase flake hosts, that's a text check — but it's also a real invariant (lowercase hosts would break the flake reference).

- [ ] **Step 2: Classify and act**

  If the test validates a real invariant (PascalCase host references), **KEEP** but add a comment explaining why the grep is necessary. If it's trivial, **REMOVE**.

- [ ] **Step 3: Commit if changed**

  ```bash
  git add -A && git commit -m "test: audit apply-dispatch-tests.sh"
  ```

### Task 5.3: Audit remaining script tests for grep-only patterns

- [ ] **Step 1: Scan all `tests/scripts/**/*-tests.sh` files**

  ```bash
  grep -rl "grep -" tests/scripts/ | head -20
  ```

- [ ] **Step 2: For each file with grep assertions, classify**

  - If grep validates a real invariant (e.g., "must not contain banned pattern"): **KEEP**
  - If grep checks implementation text (e.g., "must contain function X"): **FIX or REMOVE**

- [ ] **Step 3: Remove any confirmed low-value files**

  Commit each removal individually.

---

## Phase 6: Update Documentation

### Task 6.1: Update `testing.instructions.md`

- [ ] **Step 1: Add anti-pattern guidance**

  Add a section documenting the grep-only anti-pattern and when it's acceptable vs. when it should be converted:

  ```markdown
  ## Anti-pattern: grep-only tests

  Tests that use `builtins.readFile` + `containsRegex` / `lib.hasInfix` to check
  that specific text exists in source files are **implementation-coupled**. They
  break on code reflow, renaming, or comment changes while providing zero
  behavioral assurance.

  **Acceptable grep usage:**
  - Checking that a banned pattern does NOT appear (e.g., `!containsRegex "pip install"`)
  - Validating annotation presence (e.g., `containsRegex "# check-suppress:"`)
  - Checking for specific error message text in expected-failure tests

  **Unacceptable grep usage:**
  - Checking that a function name exists in a file
  - Checking that an import path is present
  - Checking that a specific string literal appears in source code

  Convert unacceptable patterns to behavioral tests that evaluate the module
  with fixture data and verify output attributes.
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add -A && git commit -m "docs: add grep-only anti-pattern guidance to testing.instructions.md"
  ```

---

## Phase 7: Verify No Regressions

### Task 7.1: Full test suite verification

- [ ] **Step 1: Run Nix tests**

  ```bash
  find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +
  ```

- [ ] **Step 2: Run flake check**

  ```bash
  cd src && nix flake check
  ```

- [ ] **Step 3: Run check steps**

  ```bash
  nix run ./src#check-sh
  ```

- [ ] **Step 4: Run script tests**

  ```bash
  nix run ./src#test -- --skip-steps=nix-tests,system-config-build
  ```

- [ ] **Step 5: Run Pester tests (if on Windows)**

  ```powershell
  Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose
  ```

---

## Expected Impact

| Metric | Before | After (est.) |
|--------|--------|-------------|
| Nix test files | 49 | ~40 |
| Grep-only test files | ~25 | ~10 |
| Total test assertions | ~400 | ~350 (fewer but higher quality) |
| CI time (test step) | baseline | -10-15% (fewer trivial tests) |
| False-positive breakage rate | moderate | low |

## Risk Assessment

- **Phase 1 (removals):** Low risk. All removed tests are no-ops, mock-only, or trivial grep guards. Behavioral value is zero.
- **Phase 2 (consolidation):** Low risk. Merging files preserves assertions; no logic changes.
- **Phase 3 (conversions):** Medium risk. Rewriting grep tests as behavioral tests requires understanding the module structure. May need iteration.
- **Phase 4 (fixes):** Medium risk. Partial rewrites of mixed test files.
- **Phase 5 (script removals):** Low risk. Smoke tests are covered by other checks.
