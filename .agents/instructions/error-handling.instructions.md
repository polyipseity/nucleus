---
description: "Use when deciding whether an operation should hard-error, warn-and-continue, or report info. Canonical source for error vs warning vs info severity selection across scripts, activation scripts, and host modules."
name: "Error, Warning, and Info Severity"
applyTo: "scripts/**, src/**, tests/**"
alwaysApply: true
---

# Error, warning, and info severity

This file is the canonical decision source for *when* to choose `error` (hard-error),
`warning` (continue allowed), or `info`/`notice`. The level *taxonomy* (F1 message
format, streams, colors, helpers) lives in `logging.instructions.md`; this file decides
*which level a given operation earns*. File-specific *instances* of these rules are
cross-referenced, not duplicated.

## Decision model

Select severity by whether the operation must succeed for the host to be correct.

- **ERROR (hard-error):** any required convergence or configuration operation whose
  failure means the system is misconfigured or unsafe. Surface it with a non-zero exit
  (POSIX `die`/`error` + `exit 1`; PowerShell `Write-NucleusError` + `throw`). Continuing
  past it is forbidden. Includes:
  - Privilege gap on `src/` code (see `scripts-and-permissions.instructions.md`, rule 1).
  - Inverse-family already-elevated refusal (see `scripts-and-permissions.instructions.md`, rule 3 — a hard refusal, not a warning).
  - Activation-script convergence failure (see below).
  - Secrets/identity derivation failure (age-key, GPG ownertrust, SSH fingerprint manifest).
  - Symlink creation / ACL delete-protection hardening failure.
  - Jellyfin admin-token absence (see `scripts-and-permissions.instructions.md`, Jellyfin note).
  - Allow/deny-list staleness (see `allow-and-deny-lists.instructions.md`, Tier 2).
  - Missing required tool in check/test preflight (see `tooling-and-validation.instructions.md`).
  - Cloud-drive mount/replica path conflict (see `cloud-drives-and-finder.instructions.md`).
- **WARNING (continue allowed):** genuinely optional or best-effort operations where
  skipping is safe — daemon restart when not yet running, cache clear, an expected
  runtime condition (e.g. `bootout` on an absent service, see
  `macos-service-hardening.instructions.md` M1/M2), or a by-design additive post-apply
  step whose prerequisite is absent. A warning MUST still be checked — never `|| true`
  without reason. Every warning requires an inline or preceding-line
  `# check-suppress:suppression_doc: reason` comment (see `maintain.instructions.md` MA1
  and `comment-annotations.instructions.md` CA1/CA2).
- **INFO / NOTICE:** normal progress, success, or dry-run. Never used to report a failure.

Rule of thumb: if the operation *must* succeed for the host to be correct, it is an error.
If it is *nice-to-have* and safe to skip, it is a warning *with justification*. There is
no "warning instead of error because the failure is inconvenient" category.

## Activation scripts hard-error

Activation scripts run during system configuration apply (nix-darwin `darwin-rebuild`,
Home Manager, `nixos-rebuild`, Windows DSC/`apply.ps1`). They MUST hard-error on any
required convergence failure. `warn`/`Write-NucleusWarning` + continue is banned for
required operations in activation scripts. A required op that fails must abort the
activation via `die`/`throw`, not downgrade to a warning. See
`activation-scripts.instructions.md` (`set -euo pipefail`, AC1) for the activation
script baseline.

## Do not

- Never downgrade an error to a warning, info log, or silently swallowed failure
  (see `core-behavior.instructions.md` CB2 — no silent downgrade).
- Never use `|| true`, `2>/dev/null`, or `-ErrorAction SilentlyContinue` without a
  `# check-suppress:suppression_doc: reason` comment (see `maintain.instructions.md` MA1,
  `comment-annotations.instructions.md` CA1/CA2, `core-behavior.instructions.md` CB1).
- Never mask a missing or failed value with a default (`or ""`, `?? ""`, `|| ""`,
  `dict.get(k, "")`, `-ErrorAction SilentlyContinue` without stated reason) — surface the
  failure (see `core-behavior.instructions.md` CB1, `typing-conventions.instructions.md`).
- Never add a fallback path or silent default when a primary path fails (see
  `core-behavior.instructions.md` CB1 — no fallbacks).

## Related instruction files

- `logging.instructions.md` — F1-F5 level taxonomy, streams, colors, helpers.
- `scripts-and-permissions.instructions.md` — privilege-gating (hard-error default, escalate→warn-and-skip, inverse-family hard-refuse, non-escalatable warn-and-skip, Jellyfin hard-error).
- `allow-and-deny-lists.instructions.md` — Tier 2 must-error, Tier 3 track.
- `cloud-drives-and-finder.instructions.md` — mount/replica must fail.
- `macos-service-hardening.instructions.md` — expected-condition warnings (bootout, SIP).
- `tooling-and-validation.instructions.md` — preflight hard-fail, scoped skip (exit 2).
- `core-behavior.instructions.md` — no fallbacks, no silent downgrade, match severity.
- `maintain.instructions.md` — `|| true` justification rule.
- `comment-annotations.instructions.md` — suppression semantics and enforcement greps.
- `step-runner.instructions.md` — skip ≠ failure (exit 2), fail-fast.
- `activation-scripts.instructions.md` — `set -euo pipefail` baseline for activation scripts.
- `testing.instructions.md` — fail-fast convention for check vs test.

## Disposition of every warning/error

When fixing or triaging warnings/errors, never leave one uninvestigated. For each
emitted item: capture the exact line, classify it (`fix` / `upstream` / `by-design`
/ `consequence`), and record the evidence behind the classification. "Benign"
without proof — a confirmed-running service, an intentional flag, a named upstream
bug, or a documented condition — is itself a violation of the no-silent-downgrade
rule in `core-behavior.instructions.md`. See that file's "Never silently skip
warnings or errors" section for the full protocol.
