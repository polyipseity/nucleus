---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Also covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and Validation Detection

## Discovery before prescription

- Before you write language-specific, framework-specific, runtime-specific, or automation-specific instructions, determine what the repository actually uses.
- Inspect the files that define the repository's actual setup: dependency manifests, lockfiles, build/test/linter/formatter configs, CI workflows, scripts, editor settings, automation configs, source directories, file extensions, and representative entrypoints.
- If the repository is still a sparse template, describe the workflow as conditional or not yet initialized instead of pretending commands already exist.

## Detection targets

- Detect languages, frameworks, build systems, package managers, test runners, linters, formatters, and release tooling from real config files, lockfiles, scripts, CI steps, and source files — not empty directories or assumptions from similar repos.
- Check in order: workspace guidance → dependency manifests → build/test/lint configs → CI workflows → source layouts → editor/automation configs.
- Record directory boundaries that follow different conventions for their own instruction files.

## Command discovery

- Identify canonical commands from task-runner configs, scripts, CI steps, and workspace docs.
- Record where each command comes from so instructions can be updated when the source of truth changes.
- If several entrypoints wrap the same behavior, document the canonical one and note the wrappers briefly instead of duplicating the whole command matrix.

## GitHub CLI usage (noninteractive by default)

- All `gh` commands in automation, validation, and agent execution must run in noninteractive mode.
- Set `GH_PROMPT_DISABLED=1` and `GH_PAGER=cat` when invoking `gh` to avoid blocking on prompts or pager sessions.
- Prefer explicit machine-readable output (`--json`, optionally `--jq`) over interactive flows.
- Avoid interactive commands (for example `gh run watch`) in agent workflows; poll status with noninteractive list/view commands instead.

## Config coordination

- When changing tooling instructions, update neighboring configs (CI workflows, editor/automation configs, formatting/line-ending files, prompt files) in the same pass.
- Derive test coverage counts and file lists from the current `tests/` tree and CI globs — no stale prose or placeholder absence claims.
- In instruction examples, prefer real in-repo file names unless labeled as illustrative.

## Skill vs instruction vs AGENTS.md boundary

Choose the right vehicle:

- **AGENTS.md**: durable project-wide conventions. Keep short (~30 lines max per section).
- **`.agents/instructions/*.instructions.md`**: file-type-scoped authoring rules with a narrow `applyTo` glob. Loaded automatically when editing matching files. Must be lean and targeted.
- **`.agents/skills/<skill>/SKILL.md`**: on-demand reference. Use for content too broad for an instruction file. Avoid duplicating AGENTS.md.

## How to write follow-up instructions

- When a stack gains a clear setup, create or refine a focused instruction file. Keep `applyTo` narrow, link to canonical configs instead of copying option lists, and keep repo-wide discovery in `AGENTS.md`.
- Make it evidence-backed: code structure, tests, commands, config files, source locations, common failure modes.

## Validation guidance

### Check script structure

- Both `scripts/check.sh` (POSIX) and `scripts/check.ps1` (Windows) organize check steps into five groups. Step numbers follow the `src/scripts/checks/check-steps/<nn>-*.sh|.ps1` file names — that file list is the source of truth:
  - **Toolchain checks** (1-3): Shell script formatting/linting (treefmt), PowerShell syntax, Packer templates.
  - **Nix checks** (4-6): Flake evaluation, nix lint (nixf-tidy), stale Nix build artifacts.
  - **Test suites** (7-10): Shell validation, CWD independence, nix search path, port utilities.
  - **Data integrity** (11-14): Lockfile validation, locked DSC validation, schema validation, service registry.
  - **Policy/verification** (15-23): YAML structural, package manager enforcement, error suppression, online determinism, config method compliance, activation token placeholder, preflight install-command policy, embedded-content enforcement, legacy token syntax.
- On Windows (check.ps1), steps 1, 4-6, 8-11 are stubs (POSIX/Nix-only tools).
- Pre-flight tool validation runs at the start of both scripts (before `$_step=0`). On POSIX this uses `require_command` from `src/scripts/lib.sh`; on Windows it uses `Ensure-Tool` from `src/hosts/Windows/modules/Ensure-Tool.psm1`.
- Tool provisioning is handled by `nucleus-apply` (POSIX: `home.packages` in `src/modules/core.nix`; Windows: WinGet DSC). The pre-flight block is a safety net only — `nix profile install` and similar ad-hoc provisioning are banned.
- When adding new tools to the check suite, add them to both: (a) the pre-flight block, and (b) `src/modules/core.nix` (POSIX) or WinGet DSC (Windows).

### Check mode taxonomy

Checks in both `scripts/check.sh` and `scripts/check.ps1` are classified into three categories:

- **Always-run checks**: These cannot meaningfully accept path filtering — they validate whole-repo invariants. They execute unconditionally in both `--full` and `--scoped` modes, with no `$HAS_ARGS` guard. Examples: stale Nix build artifacts (step 6), test suites (steps 7-10), locked DSC validation (step 12), service registry validation (step 14), config method compliance (step 19).
- **Conditional checks**: These run only when certain file types are present in the changed set (scoped mode), or always in `--full` mode. Examples: Nix flake evaluation (step 4 — in `--full` mode it always evaluates the flake; in `--scoped` mode only when .nix files are in scope), lockfile validation (step 11, matches `*/lockfile.json`/`*/lifecycle-allowlist.json`), package manager enforcement (step 16, matches `*.sh|*.ps1|*.nix`).
- **Path-scopable checks**: These operate per-file or per-file-type and accept path filtering in `--scoped` mode. They produce valid results when given only the changed file subset. Examples: Shell script formatting/linting (step 1), PowerShell syntax (step 2), Packer validation (step 3), Nix lint/nixf-tidy (step 5), schema validation (step 13), YAML structural validation (step 15), undocumented error suppression (step 17), activation token placeholder (step 20).

**Source of truth**: The check-step file names under `src/scripts/checks/check-steps/` and their header docstrings are the canonical step-by-step reference. Update both check scripts when changing the taxonomy.

### Scoped-mode conventions (`_has_args`)

Check steps receive scoped file sets when prek passes staged files as args:

- **POSIX**: step functions receive `$1=_has_args`, `$2=_repo_root`, remaining args = scoped files. Scoped skip pattern (steps 11, 16): loop the scoped files for a type match; if none, print `==== N: Name ==== SKIPPED (no X files to check)` and `return 0`.
- **PowerShell**: steps are splatted with named params `param($HasArgs, $RepoRoot, $PositionalArgs)` (step-runner.ps1). Skip check: count matching `$PositionalArgs`; if none, emit `... SKIPPED ...` and `return $true`.
- **Scoped-mode `$null` trap**: building a scoped file list as an if-EXPRESSION pipeline-enumerates branch output — an empty scoped list enumerates away to `$null`, so `.Count` throws under StrictMode (steps 21/22 hit this). Wrap the whole outer if-expression in `@(...)` (e.g. `$ps1Files = @(if ($HasArgs) {...} else {...})`) with a `# WHY:` comment.
- Per-step explicit-skip tests live in `tests/scripts/check-steps/<nn>-<step>-explicit-skip.sh|.ps1`, wired into `05-framework-verification.sh|.ps1` in numeric order. `.sh` tests may source the real step file and invoke `run_NN_* true "$REPO_ROOT" <file>` to assert SKIPPED behavior (grep-based assertions, `# shellcheck disable=SC2016` for literal patterns). New `.sh` tests `chmod +x`; `.ps1` stay `644`.
- End-to-end scoped check: `scripts/check.sh README.md` → steps 11+16 SKIP, exit 0; `scripts/check.sh src/modules/core.nix` → step 16 runs its scan, exit 0.

- For every detected stack, document what to run and where commands are defined.
- **Nix check-and-format (pre-commit hook)**: `check.sh` accepts `--format` to auto-fix Nix files (treefmt runs nixfmt-rfc-style for Nix formatting when invoked in-place). The flag is passed by `prek-hooks.py` when `args = ["--format"]` in `prek.toml`. `treefmtWrapper` is bundled in `mkCheckApp` runtimeInputs in `src/flake.nix`. No separate `format-nix` hook exists.
- **deadnix in test files**: deadnix runs on all `.nix` files including tests — no excludes are configured. deadnix findings in test files are **not false positives**. Due to Nix's lazy evaluation, a `let` binding that is not syntactically referenced from the test's final return expression is genuinely never evaluated. If deadnix reports a binding as unused, the correct fix is to either remove it or force evaluation (see `deepSeq` pattern below). Do not suppress deadnix warnings or re-add `tests/**` excludes.

  The canonical fix for test bindings that should be evaluated: wrap the test result in `builtins.seq (builtins.deepSeq { ... } null)`. `builtins.deepSeq` is TWO-arg (`deepSeq a b` returns `b` after deep-forcing `a`); the one-arg form returns a partial lambda (WHNF), so `seq` skips forcing and every assertion is dead code while tests still report success. Known trap: many `tests/` files still use the one-arg form — fix them when touched:

  ```nix
  in
  builtins.seq (builtins.deepSeq {
    inherit test1 test2 test3;
  } null) {
    success = true;
    message = "All checks passed";
  }
  ```

  The pragma `# deadnix: skip` is available for rare cases where a binding must remain syntactically unused (e.g. a placeholder for future tests). Use it only as a last resort.

- **Commit message validation**: commitlint (via `prek.toml` commit-msg hook) enforces conventional commit types. Valid types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Do not use `maintain` — use `refactor` for cleanup without behavior change or `chore` for config/tooling maintenance. For pre-validation use the temp-dir install fallback in `commit.instructions.md` (`bun install` into a `mktemp -d` dir, run commitlint there) — `bun x commitlint` cannot pre-validate messages in this manifest-less repo: even with `--default-config`, bun's global cache cannot resolve `conventional-changelog-conventionalcommits` from the transpiled `noop.js` (`ResolveMessage: Cannot find package`). The structural check (`type(scope): subject`) is the last resort when bun is unavailable. `bun install` artifacts (`package.json`, `bun.lock`, `node_modules`) are NOT gitignored — remove them after validation.
- **prek hook stashing**: prek hooks stash unstaged changes during commit execution, run checks, then restore them. Stashing output during commits is normal, not an error. Because the `repo-check` hook checks only the staged subset, each atomic commit must leave the whole repo passing.
- **prek concurrent treefmt race**: prek runs the local `repo-check` hook in concurrent batches (≤4 files/batch) when many files are staged; concurrent `scripts/check.sh --scoped` runs then race on treefmt, and the bbolt eval-cache can time out its flock (~1.3s) even with a warm cache. `PREK_CONCURRENT_BATCHES=1 git commit ...` serializes batches. (Alternative: `require_serial = true` hook option in `prek.toml` — a repo change.)
- **CI policy**: Do not add new checks or tests to `ci.yml`. Route new validation into repo checks (`scripts/check.sh` / `scripts/check.ps1`) or repo tests (`tests/`). Decouples checks from CI runners so they work locally too.
- When specific identifiers/settings are not covered by executable validation (for example app IDs, bundle IDs, launch labels, registry keys, env-var names, or preference domains), require inline source citations adjacent to those settings so reviewers can verify each one independently.
- Treat syntax validation as mandatory: always run at least one syntax/parse check for each changed file type before concluding. Prefer repository-defined commands (for example `nix-instantiate --parse <file.nix>`, `nix flake check` from `src/`, `nix shell nixpkgs#powershell -c pwsh ...`, and `winget configure --what-if .\src\hosts\windows\system.dsc.yml` / `winget configure --what-if .\src\hosts\windows\system-packages.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user-env.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user-context.dsc.yml`).
- When no runnable validation exists yet, say that explicitly and point to the files that would need to be added before validation can be automated.

## What to avoid

- Do not assume a default language or task runner just because a similar repo used one.
- Do not keep stale stack-specific files after the repo has been generalized or reoriented.
- Do not leave broad placeholders such as "follow standard best practices" when concrete repository evidence can support sharper guidance.
