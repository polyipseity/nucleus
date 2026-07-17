---
status: in-progress
committed: partial
current-step: 8
inputs:
  atomicCommits: true
  backwardsCompat: no
  maxConcurrency: 1
---

# Plan: Script Organization Overhaul — Phase 2

**Status**: in-progress
**Goal**: Address all 9+ user concerns about script categorization, naming, and structure quality.

## Summary of Changes

| Concern | Action |
|---|---|
| agents-install-bun-packages.sh not agents-specific | Move to `home/` as `install-bun-packages.sh` |
| Need services/ directory | Create `services/`, move 8 daemon/service scripts there |
| dev/ can be subsumed under home/ | Delete `dev/`, move its scripts to `services/` (they are launchd agents, not HM steps) |
| host/nixos/ capitalization | Rename to `host/NixOS/` |
| agent-helpers misleading name | Rename to `symlink-hardening-lib.sh` |
| Fix filename → activation entry name | Update activation entries when filenames change |
| caddy-trust, gc-weekly, nix-index-update not macos-only | Move all 3 out of `macos/` |
| verify-homebrew-unpinnable not secrets | Move to `macos/` |
| Many more problems | Includes dead file cleanup, broken-path fixes from Phase 1 |

---

## New Proposed Structure

```
src/scripts/
├── apply.sh                          (root — stay)
├── caddy-trust.sh                    (from macos/, not macOS-only)
├── install-prek-hooks.sh             (root — stay)
├── wallpaper-provision.sh            (root — stay)
├── obsidian-merge-json.py            (root — stay)
│
├── services/                         (NEW — all persistent daemon/service scripts)
│   ├── betterdisplay-heartbeat.sh    (from macos/)
│   ├── camilladsp-daemon.sh          (from camilladsp/)
│   ├── camilladsp-heartbeat.sh       (from camilladsp/)
│   ├── ds-store-gc.sh                (from dev/dev-ds-store-gc.sh — renamed)
│   ├── gc-weekly.sh                  (from macos/)
│   ├── gui-env.sh                    (from macos/gui-env-agent.sh — renamed, activation was already `gui-env`)
│   ├── nix-index-update.sh           (from macos/)
│   └── spotlight-exclusions.sh       (from dev/dev-spotlight-exclusions.sh — renamed)
│
├── lib/                              (shared libraries)
│   ├── cloud-drive-setup-lib.sh      (stay)
│   ├── dev-repos-provision-lib.sh    (stay)
│   ├── icloud-exclusions-lib.sh      (stay)
│   ├── lib.sh                        (stay)
│   ├── symlink-hardening-lib.sh      (NEW NAME — was agent-helpers.sh)
│   └── vm-setup-lib.sh               (stay)
│
├── secrets/                          (secret provisioning)
│   ├── secrets-git-identity.sh       (stay)
│   ├── secrets-gpg-import.sh         (stay)
│   ├── secrets-ssh-key-adopt.sh      (stay)
│   ├── generate-ssh-host-key.sh      (stay)
│   └── register-host-age-key.sh      (stay)
│
├── home/                             (Home Manager activation helpers)
│   ├── install-bun-packages.sh       (from agents/agents-install-bun-packages.sh — renamed)
│   ├── picard-merge-ini.sh           (stay)
│   └── qtpass-merge-ini.sh           (stay)
│
├── host/                             (host-specific scripts)
│   ├── jellyfin-sync.sh              (stay)
│   └── NixOS/                        (was nixos/ — capitalized)
│       └── nixos-activation-setup.sh (stay)
│
├── agents/                           (AI agent setup — only agent-specific scripts remain)
│   ├── agents-skills.sh              (stay)
│   └── agents-symlink.sh             (stay)
│
└── macos/                            (macOS-specific activation — no daemons, only activation steps)
    ├── macos-app-bundle-lib.sh
    ├── macos-battery-policy.sh
    ├── macos-charge-limit.sh
    ├── macos-clear-finder-cache.sh
    ├── macos-color-profile.sh
    ├── macos-disable-spotlight.sh
    ├── macos-disable-steam-autostart.sh
    ├── macos-display-resolutions.sh
    ├── macos-ensure-launchagents.sh
    ├── macos-gimp-scroll-sensitivity.sh
    ├── macos-gui-env-path.sh
    ├── macos-headless-display.sh
    ├── macos-input-config.sh
    ├── macos-launch-services.sh
    ├── macos-linearmouse-config.sh
    ├── macos-linearmouse-prefs.sh
    ├── macos-middle-click.sh
    ├── macos-mission-control.sh
    ├── macos-mounty-login-item.sh
    ├── macos-networking-setup.sh
    ├── macos-nightlight.sh
    ├── macos-ntfs3g-build.sh
    ├── macos-nvim-launcher.sh
    ├── macos-preference-gc.sh
    ├── macos-raycast-aliases.sh
    ├── macos-rosetta-install.sh
    ├── macos-safari-defaults.sh
    ├── macos-ssh-access.sh
    ├── macos-universal-access-defaults.sh
    ├── macos-verify-homebrew.sh
    └── verify-homebrew-unpinnable.sh  (NEW — from secrets/)
```

### Deleted directories
- `src/scripts/camilladsp/` — contents moved to `services/`
- `src/scripts/dev/` — contents moved to `services/`
- `src/scripts/host/nixos/` → renamed to `host/NixOS/`

### Dead files to verify + remove
- `src/scripts/picard-apply-defaults.awk` (zero references anywhere)
- `src/scripts/picard-upsert-ini.awk` (zero references anywhere)
- `src/scripts/qtpass-upsert-ini.awk` (zero references anywhere)

---

## Phase 0: Fix Broken Runtime Paths (from Phase 1)

These 8 paths are currently broken and must be fixed regardless of other changes.

| File | Wrong Reference | Correct |
|---|---|---|
| `src/scripts/apply.sh:251,273` | `$_ash_script_dir/generate-ssh-host-key.sh` | `$_ash_script_dir/secrets/generate-ssh-host-key.sh` |
| `src/scripts/apply.sh:252,274` | `$_ash_script_dir/register-host-age-key.sh` | `$_ash_script_dir/secrets/register-host-age-key.sh` |
| `src/scripts/apply.sh:259,280,296` | `$REPO_ROOT/src/scripts/jellyfin-sync.sh` | `$REPO_ROOT/src/scripts/host/jellyfin-sync.sh` |
| `tests/integration/symlink-hardening-tests.nix:11` | `../../src/scripts/agent-helpers.sh` | `../../src/scripts/lib/agent-helpers.sh` |
| `tests/integration/jellyfin-provisioning-tests.nix:24` | `../../src/scripts/caddy-trust.sh` | `../../src/scripts/macos/caddy-trust.sh` |
| `tests/integration/jellyfin-provisioning-tests.nix:31` | `../../src/scripts/jellyfin-sync.sh` | `../../src/scripts/host/jellyfin-sync.sh` |
| `tests/integration/log-rotation-tests.nix:6` | `../../src/scripts/lib.sh` | `../../src/scripts/lib/lib.sh` |
| `tests/integration/check-tests.nix:11` | `../../src/scripts/lib.sh` | `../../src/scripts/lib/lib.sh` |

**Important**: Phase 0 must be applied and committed FIRST since subsequent renames will change paths again.

---

## Phase 1: Create `services/` directory

### 1a. Move service scripts from `camilladsp/` → `services/`

```
git mv src/scripts/camilladsp/camilladsp-daemon.sh src/scripts/services/camilladsp-daemon.sh
git mv src/scripts/camilladsp/camilladsp-heartbeat.sh src/scripts/services/camilladsp-heartbeat.sh
```

**Nix refs to update**:
- `src/hosts/NixOS/camilladsp.nix:18-19` — `../../scripts/camilladsp/` → `../../scripts/services/`
- `src/hosts/MacBook/camilladsp.nix:23-24` — `../../scripts/camilladsp/` → `../../scripts/services/`

### 1b. Move service scripts from `macos/` → `services/`

```
git mv src/scripts/macos/betterdisplay-heartbeat.sh src/scripts/services/betterdisplay-heartbeat.sh
git mv src/scripts/macos/gc-weekly.sh src/scripts/services/gc-weekly.sh
git mv src/scripts/macos/gui-env-agent.sh src/scripts/services/gui-env.sh      # renamed!
git mv src/scripts/macos/nix-index-update.sh src/scripts/services/nix-index-update.sh
```

**Nix refs to update (src/modules/macos.nix)**:
- Line 226: `../scripts/macos/betterdisplay-heartbeat.sh` → `../scripts/services/betterdisplay-heartbeat.sh`
- Line 290: `../scripts/macos/gc-weekly.sh` → `../scripts/services/gc-weekly.sh`
- Line 300: `../scripts/macos/gui-env-agent.sh` → `../scripts/services/gui-env.sh`
- Line 240: `../scripts/macos/nix-index-update.sh` → `../scripts/services/nix-index-update.sh`

Also update `pkgs.writeShellScript "gui-env-agent"` at line 293 → `pkgs.writeShellScript "gui-env"` (activation-name consistency).

### 1c. Move service scripts from `dev/` → `services/` (with rename)

```
git mv src/scripts/dev/dev-ds-store-gc.sh src/scripts/services/ds-store-gc.sh        # renamed
git mv src/scripts/dev/dev-spotlight-exclusions.sh src/scripts/services/spotlight-exclusions.sh  # renamed
```

**Nix refs to update (src/modules/macos.nix)**:
- Line 277: `../scripts/dev/dev-spotlight-exclusions.sh` → `../scripts/services/spotlight-exclusions.sh`
- Line 285: `../scripts/dev/dev-ds-store-gc.sh` → `../scripts/services/ds-store-gc.sh`

**Activation entry updates**:
- Line 273: `pkgs.writeShellScript "dev-spotlight-exclusions"` → `pkgs.writeShellScript "spotlight-exclusions"`
- Line 284: `pkgs.writeShellScript "dev-ds-store-gc"` → `pkgs.writeShellScript "ds-store-gc"`
- Line 763: `launchd.agents."dev-ds-store-gc"` → `launchd.agents."ds-store-gc"`
- Line 766: `Label = "local.dev-ds-store-gc"` → `Label = "local.ds-store-gc"`
- Line 780: `launchd.agents."dev-spotlight-exclusions"` → `launchd.agents."spotlight-exclusions"`
- Line 783: `Label = "local.dev-spotlight-exclusions"` → `Label = "local.spotlight-exclusions"`

### 1d. Delete empty source directories

```
git rm -r src/scripts/camilladsp/
git rm -r src/scripts/dev/
```

---

## Phase 2: Rename `agent-helpers.sh` → `symlink-hardening-lib.sh`

```
git mv src/scripts/lib/agent-helpers.sh src/scripts/lib/symlink-hardening-lib.sh
```

**Nix refs to update** (all `../scripts/lib/agent-helpers.sh` → `../scripts/lib/symlink-hardening-lib.sh`):
- `src/modules/agents.nix:28`
- `src/modules/macos.nix:319,324,440`
- `src/modules/custom-provision-symlinks.nix:139,156`
- `src/modules/editors.nix:478,605`
- `src/modules/dev-repos.nix:137`
- `src/modules/home.nix:258,268`
- `src/modules/lib/config-utils.nix:16`
- `tests/integration/symlink-hardening-tests.nix:11` (already fixed in Phase 0)

**Optional**: rename `agentHelpersSh` variable in Nix files for consistency (not required by filename=activation rule since lib files aren't activation entries).

---

## Phase 3: Move `verify-homebrew-unpinnable.sh` from `secrets/` → `macos/`

```
git mv src/scripts/secrets/verify-homebrew-unpinnable.sh src/scripts/macos/verify-homebrew-unpinnable.sh
```

**Runtime path to update**:
- `src/scripts/macos/macos-verify-homebrew.sh:8-9`: `$hb_repo_root/src/scripts/secrets/verify-homebrew-unpinnable.sh` → `$hb_repo_root/src/scripts/macos/verify-homebrew-unpinnable.sh`

---

## Phase 4: Move `agents-install-bun-packages.sh` from `agents/` → `home/` (rename)

```
git mv src/scripts/agents/agents-install-bun-packages.sh src/scripts/home/install-bun-packages.sh
```

**Nix refs to update**:
- `src/modules/agents.nix:134`: `../scripts/agents/agents-install-bun-packages.sh` → `../scripts/home/install-bun-packages.sh`
- The activation entry `installBunPackages` stays in `agents.nix` (the activation step, not the file, determines where it belongs functionally). No need to move the activation entry.

---

## Phase 5: Move `caddy-trust.sh` from `macos/` → root of `src/scripts/`

```
git mv src/scripts/macos/caddy-trust.sh src/scripts/caddy-trust.sh
```

**Nix refs to update**:
- `src/scripts/apply.sh:195`: `$REPO_ROOT/src/scripts/macos/caddy-trust.sh` → `$REPO_ROOT/src/scripts/caddy-trust.sh`
- `tests/integration/jellyfin-provisioning-tests.nix:24` (already fixed in Phase 0)
- `.agents/instructions/macos-launchd-sip.instructions.md:4` — update path reference
- `.agents/instructions/scripts-and-permissions.instructions.md:31` — update path reference

Note: `caddy-trust.sh` sources `lib.sh` at runtime via `SCRIPT_DIR` resolution, so moving to root changes the relative path. Verify the source line works correctly.

---

## Phase 6: Rename `host/nixos/` → `host/NixOS/`

```
git mv src/scripts/host/nixos/ src/scripts/host/NixOS/
```

**Nix refs to update**:
- `src/hosts/NixOS/activation.nix:39,50,84`: `../../scripts/host/nixos/` → `../../scripts/host/NixOS/`
- `src/hosts/NixOS/desktop.nix:214`: `../../scripts/host/nixos/` → `../../scripts/host/NixOS/`

---

## Phase 7: Update activation entry names (consistency rules)

For every renamed file, ensure the activation entry name matches the filename.

| File Change | Activation Entry Change | Where |
|---|---|---|
| `gui-env-agent.sh` → `gui-env.sh` | `pkgs.writeShellScript "gui-env-agent"` → `"gui-env"` | `src/modules/macos.nix:293` |
| `dev-ds-store-gc.sh` → `ds-store-gc.sh` | `pkgs.writeShellScript "dev-ds-store-gc"` → `"ds-store-gc"` | `src/modules/macos.nix:284` |
| `dev-ds-store-gc.sh` → `ds-store-gc.sh` | `launchd.agents."dev-ds-store-gc"` → `"ds-store-gc"` | `src/modules/macos.nix:763` |
| `dev-ds-store-gc.sh` → `ds-store-gc.sh` | `Label = "local.dev-ds-store-gc"` → `"local.ds-store-gc"` | `src/modules/macos.nix:766` |
| `dev-spotlight-exclusions.sh` → `spotlight-exclusions.sh` | `pkgs.writeShellScript "dev-spotlight-exclusions"` → `"spotlight-exclusions"` | `src/modules/macos.nix:273` |
| `dev-spotlight-exclusions.sh` → `spotlight-exclusions.sh` | `launchd.agents."dev-spotlight-exclusions"` → `"spotlight-exclusions"` | `src/modules/macos.nix:780` |
| `dev-spotlight-exclusions.sh` → `spotlight-exclusions.sh` | `Label = "local.dev-spotlight-exclusions"` → `"local.spotlight-exclusions"` | `src/modules/macos.nix:783` |

Note: `writeShellScript` package names are not activation entries per se, but they appear in the Nix store and should be consistent. `launchd.agents` label changes affect service management.

---

## Phase 8: Clean up dead files

Verify that the 3 `.awk` files are truly unused (already confirmed by exhaustive grep with zero results), then:

```
git rm src/scripts/picard-apply-defaults.awk
git rm src/scripts/picard-upsert-ini.awk
git rm src/scripts/qtpass-upsert-ini.awk
```

---

## Phase 9: Update documentation

- `AGENTS.md` — update script organization section with new structure
- `.agents/instructions/nix-authoring.instructions.md` — update path conventions
- `/memories/repo/maintain-notes.md` — update with new conventions

Also check for any `applyTo` patterns in instruction files that reference old paths.

---

## Execution Order

Phase 0 must be committed first (fixes actual bugs). Phases 1-8 can be ordered for minimal merge conflicts but each changes different files so any order is viable. Recommended:

1. **Phase 0** — Fix broken paths (commit)
2. **Phase 7** — Update activation entry names (do before moving files) → OR combine with Phase 1
3. **Phase 1** — Create `services/` (commit)
4. **Phase 2** — Rename `agent-helpers.sh` (commit)
5. **Phase 3** — Move `verify-homebrew-unpinnable.sh` (commit)
6. **Phase 4** — Move `agents-install-bun-packages.sh` (commit)
7. **Phase 5** — Move `caddy-trust.sh` (commit)
8. **Phase 6** — Capitalize `NixOS/` (commit)
9. **Phase 8** — Remove dead files (commit)
10. **Phase 9** — Documentation (commit)

Each phase should be validated with `nix flake check --no-build` from `src/` before committing.

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| Activation entry rename (gui-env-agent → gui-env) may affect running services | Launchd looks at `Label` which stays `local.gui-env`; only the `launchd.agents` key changes. `nucleus-svc` may need update if it references by key name. |
| caddy-trust.sh sources lib.sh via relative path; moving breaks source | Verify `SCRIPT_DIR` resolution in caddy-trust.sh — it uses `$(dirname "$0")` so it will find lib.sh at `src/scripts/lib/lib.sh` correctly from `src/scripts/caddy-trust.sh` (moving UP one level). |
| Many touchpoints on macos.nix increases error risk | Commit Phase 1 separately with careful regex-based sed; validate with `nix flake check`. |
