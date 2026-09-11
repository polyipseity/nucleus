---
description: "Use when adding, editing, or reviewing launchd daemons/agents on macOS (nix-darwin), or porting equivalent systemd user services on NixOS/Windows. Covers the three mechanisms, multi-user-by-default rule, and user-launch-agent preference."
name: "launchd mechanism policy"
applyTo: "src/**/*.nix, src/platforms/macOS/**, src/hosts/MacBook/**, tests/**/*.nix"
---

# launchd mechanism policy (macOS / nix-darwin)

## The three mechanisms

| Mechanism | nix-darwin option | Install path | launchd domain | Runs as | GUI / TCC | Runs w/o login | Job scope |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Daemon** | `launchd.daemons` | `/Library/LaunchDaemons` | `system` | root (or `UserName`) | **No** | **Yes** | system-wide |
| **Global agent** | `launchd.agents` | `/Library/LaunchAgents` | `gui` (per logged-in user) | each logged-in user | **Yes** | No | **all logged-in users** |
| **User agent** | `environment.userLaunchAgents` (a.k.a. `launchd.user.agents`) | `~/Library/LaunchAgents` | `gui/<uid>` | primary user | **Yes** | No | **primary user only** |

Source: Apple *Daemons and Services Programming Guide* /
[launchd.info](https://www.launchd.info/) and nix-darwin `modules/launchd/default.nix`.

All three generate plists via `generators.toPlist { escape = true; }` — byte-identical to manual builds.

**Global-agent `launchctl` warning:** nix-darwin loads `/Library/LaunchAgents` plists as root → `launchctl load` infers `system` domain from EUID → mismatch warning + `Load failed: 5`. nix-darwin then re-bootstraps into `gui/<uid>`, which succeeds. This is an activation artifact, not a daemon/agent mismatch.

**User-agent load pattern:** `launchctl asuser <uid> sudo --user=<user> -- launchctl load -w ~<user>/Library/LaunchAgents/...` (same as nix-darwin `org.nixos.gnupg-agent`). No root/domain mismatch.

## Rule 1 — assume multi-user by default

**Never assume single-user. Design for multiple concurrent users on every platform.**

Scope choice is driven by job requirements, not user count:

1. Needs **no user logged in**, no GUI/TCC, or root-owned resources → **daemon** (`launchd.daemons`)
2. Needs **GUI/TCC** + **all logged-in users** → **global agent** (`launchd.agents`)
3. Needs **GUI/TCC** + **primary user only** → **user launch agent** (`environment.userLaunchAgents`)

Mis-scoping an all-user job as a user agent silently drops it for other users.

## Rule 2 — prefer user launch agents

**Prefer `environment.userLaunchAgents` over `launchd.agents` unless the job is provably all-user.**

User agents: `~/Library/LaunchAgents`, per-user `gui/<uid>`, individual enable/disable/config. Global agents: `/Library/LaunchAgents`, shared definition, triggers root-domain warning. Use global only when the job must run for every logged-in user identically.

### Activation-restart gap — use HM `launchd.agents` (domain = "gui") for persistent daemons

`environment.userLaunchAgents` only `launchctl load`s an agent if NOT already loaded. It does not restart a loaded agent when its plist changes. A `KeepAlive` agent runs the stale binary across every `nucleus-apply` until logout. (camilladsp-heartbeat ran a pre-fix binary for days after deploy.)

For any persistent user-scoped job (KeepAlive / Restart=always / long-lived loop), use Home Manager `launchd.agents.<name>` with `domain = "gui"` instead. HM's `setupLaunchAgents` does `cmp -s` and bootout+bootstrap on plist change — takes effect on next apply. Install path and `gui/<uid>` bootstrap target are identical; TCC scope and per-user configurability are unchanged.

Reserve `environment.userLaunchAgents` for short-lived jobs in the nix-darwin config context (`hosts/MacBook/*.nix` imported via `MacBook/default.nix`). Do not introduce new persistent `environment.userLaunchAgents` entries.

## Plist generation for `environment.userLaunchAgents`

Takes raw `text` (plist string), not `serviceConfig`. Build from the same attrset:

```nix
environment.userLaunchAgents."<name>" = {
  text = lib.generators.toPlist { escape = true; } {
    Label = "local.<name>";
    ProgramArguments = [ "..." ];
    RunAtLoad = true;
    # ... rest of serviceConfig keys
  };
};
```

Byte-identical to `launchd.agents` output; differs only in install location (`/Library` → `~/Library`) and load context (root → user). Standardize on `serviceConfig`-shaped attrsets (rename legacy `config = { ... }`).

## User agent in Home Manager modules

`environment.userLaunchAgents` is nix-darwin top-level — **invalid** inside HM modules (`home.nix`, `home-manager.sharedModules`). Build fails with `home-manager.users.<user>.environment does not exist`.

In HM module context, use HM's native `launchd.agents.<name>` with `domain = "gui"`:

```nix
launchd.agents."<name>" = {
  domain = "gui";
  config = {
    Label = "local.<name>";
    ProgramArguments = [ "..." ];
    RunAtLoad = true;
  };
};
```

Use for all primaryUser-scoped persistent agents — including those whose derivation lives in the darwin config, written as `home-manager.users.<user>.launchd.agents` (`src/hosts/MacBook/camilladsp.nix`) — and in HM modules (`src/platforms/macOS/modules/launchd-agents.nix`, `src/modules/ext-discord-music-rpc.nix`, `src/modules/cloud-drives.nix`). Reserve `environment.userLaunchAgents` for short-lived jobs in the nix-darwin config context; no persistent entry uses it.
