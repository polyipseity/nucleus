---
description: "Use when adding, editing, or reviewing launchd daemons/agents on macOS (nix-darwin), or porting equivalent systemd user services on NixOS/Windows. Covers the three mechanisms, multi-user-by-default rule, and user-launch-agent preference."
name: "launchd mechanism policy"
applyTo: "src/**/*.nix, src/platforms/macOS/**, src/hosts/MacBook/**, tests/**/*.nix"
---

# launchd mechanism policy (macOS / nix-darwin)

## The three mechanisms

| Mechanism | nix-darwin option | Install path | launchd domain | Runs as | GUI / TCC | Runs w/o login | Job scope |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Daemon** | `launchd.daemons` | `/Library/LaunchDaemons` | `system` | root (or `UserName`) | No | Yes | system-wide |
| **Global agent** | `launchd.agents` | `/Library/LaunchAgents` | `gui` (per logged-in user) | each logged-in user | Yes | No | all logged-in users |
| **User agent** | `environment.userLaunchAgents` (a.k.a. `launchd.user.agents`) | `~/Library/LaunchAgents` | `gui/<uid>` | primary user | Yes | No | primary user only |

Source: Apple *Daemons and Services Programming Guide* / [launchd.info](https://www.launchd.info/), and nix-darwin `modules/launchd/default.nix`. All three generate plists via `generators.toPlist { escape = true; }`.

A global-agent `launchctl` warning is an activation artifact, not a mismatch: nix-darwin loads `/Library/LaunchAgents` plists as root, `launchctl load` infers the `system` domain from the EUID, and the load fails with 5 before nix-darwin re-bootstraps into `gui/<uid>`. The user-agent load pattern avoids it entirely: `launchctl asuser <uid> sudo --user=<user> -- launchctl load -w ~<user>/Library/LaunchAgents/...` (same as nix-darwin `org.nixos.gnupg-agent`).

## Rule 1: assume multi-user by default

Never design for a single user. Scope follows the job's requirements:

1. Needs no logged-in user, no GUI/TCC, or root-owned resources → daemon (`launchd.daemons`)
2. Needs GUI/TCC for every logged-in user → global agent (`launchd.agents`)
3. Needs GUI/TCC for the primary user only → user launch agent

Mis-scoping an all-user job as a user agent silently drops it for everyone else.

## Rule 2: prefer user launch agents

A global agent means a shared definition under `/Library/LaunchAgents` plus the root-domain warning above; use one only when the job must run identically for every logged-in user.

## Persistent jobs use Home Manager `launchd.agents` with `domain = "gui"`

`environment.userLaunchAgents` only `launchctl load`s an agent that is not already loaded, so a `KeepAlive` job runs its stale binary across every `nucleus-apply` until logout. HM's `setupLaunchAgents` does `cmp -s` and bootout+bootstrap on a plist change, so anything persistent (KeepAlive, `Restart = always`, a long-lived loop) belongs in HM `launchd.agents.<name>` with `domain = "gui"`: same install path, same `gui/<uid>` bootstrap target, same TCC scope, and per-user configurability.

`environment.userLaunchAgents` is nix-darwin top-level and invalid inside HM modules (`home.nix`, `home-manager.sharedModules`); a build fails with `home-manager.users.<user>.environment does not exist`. In the nix-darwin config context (`hosts/MacBook/*.nix` via `MacBook/default.nix`) it takes raw `text` instead of `serviceConfig`, and in HM modules the same attrset shape goes under `config`. No persistent entry uses it; reserve it for short-lived jobs.

```nix
launchd.agents."<name>" = {
  domain = "gui";
  config = {
    Label = "local.<name>";
    ProgramArguments = [ "..." ];
    RunAtLoad = true;
    # ... rest of serviceConfig keys
  };
};
```

In the darwin config, write the same keys through `lib.generators.toPlist { escape = true; }` as the `text` value. Primary-user persistent agents currently live in `src/hosts/MacBook/camilladsp.nix` (as `home-manager.users.<user>.launchd.agents`), `src/platforms/macOS/modules/launchd-agents.nix`, `src/modules/ext-discord-music-rpc.nix`, and `src/modules/cloud-drives.nix`.
