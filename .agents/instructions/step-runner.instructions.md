---
description: "Use when implementing or modifying the check and test step-runner framework."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework

`step-runner.sh` and `step-runner.ps1` share one interface. `register_step(id,name,func)` defaults `any`/`any`/`none`; the 6-argument form declares applicability, the 4-argument form is for tests. Ids are unique, kebab-case, digit-free, numbered from `NN-`; tokens are platform `any|posix|windows`, mode `any|full|scoped`, requires `none|nix|network|sops-machine-key|deployed-host`. Bad tokens or numbers hard-error. Skips report `not-selected`, platform, mode, or requires reasons in that order and never affect exit code.

`--only-steps=id1,id2` requires `=`, trims and collapses ids, treats empty as no-op, last flag wins, and unknown ids hard-error. Work queue uses `PARALLEL_JOBS`, `NUCLEUS_STEP_PROGRESS_INTERVAL` (15 s default, 0 disables), and `NUCLEUS_STEP_TIMEOUT` (600 s default, 0 disables, expiry exit 124). POSIX polls on 0.25 s; PowerShell uses one runspace per step, not `RunspacePool` or `Start-Job`. `--fail-fast` drains in-flight steps then fails.

Step 7 requires inline co-located `$schema` for nucleus JSON/YAML, with A8 exceptions. Step numbers come from `NN-` filenames; renumber and sweep references in one commit. A step reads only its context parameter and locals; documented env inputs are the exception. Color lives in shared helpers; raw ANSI, `tput`, and `echo -e` are banned outside them.

Details: `.agents/skills/nucleus-platform-reference/references/step-runner.md`.
