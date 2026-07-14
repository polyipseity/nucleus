# Sorting/ordering policy for macOS context-menu services

## Policy

**All service entry lists are manually maintained in their declared order. No automatic re-sorting.**

This directory has two service types, each with its own ordering rule:

| List | File | Ordering |
|------|------|----------|
| `currentNucleusAppBundles` | `app-bundles.nix` | Alphabetical by `appDir` |
| `currentNucleusWorkflows` | `automator-workflows.nix` | Quality-descending: `default` → `prepress` → `printer` → `ebook` → `screen` |

## Cross-platform exception

The Optimize PDF presets use the same quality-descending order across all three platforms:

- **macOS**: `automator-workflows.nix` → `currentNucleusWorkflows`
- **NixOS**: `NixOS/services.nix` → `gsPdfOptPresets`
- **Windows**: `Windows/user/context-pdf-opt.dsc.yml`

This order reflects Ghostscript's quality spectrum: highest quality first (`default`/`prepress`), descending to lowest (`screen`).

## How to add a new entry

1. Determine which list the entry belongs to.
2. Find the correct insertion position:
   - For `currentNucleusAppBundles`: alphabetical by `appDir`.
   - For `currentNucleusWorkflows`: quality-descending by preset (default → prepress → printer → ebook → screen).
3. Insert the entry at that position.
4. Update the tests in `tests/integration/gs-pdf-opt-presets-tests.nix`:
   - Add new `appDir` or `dir` values to the position-comparison tests.
5. Run `nix flake check` to validate.

## Enforcement

Ordering is verified at evaluation time by tests in `tests/integration/gs-pdf-opt-presets-tests.nix` (file-position comparison) and `tests/integration/activation-deps-tests.nix` (no-reordering assertions).
