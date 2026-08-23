---
description: "Use when adding, editing, or reviewing launchd daemons/agents on macOS (nix-darwin), or porting equivalent systemd user services on NixOS/Windows. Covers the three mechanisms, the multi-user-by-default rule, and the user-launch-agent preference."
name: "launchd mechanism policy"
applyTo: "src/**/*.nix, src/platforms/macOS/**, src/hosts/MacBook/**, tests/**/*.nix"
---

# launchd mechanism policy (macOS / nix-darwin)

## The three mechanisms

These are three distinct things with different domains, privileges, and
lifecycles. Source: Apple *Daemons and Services Programming Guide* /
[launchd.info](https://www.launchd.info/) (location→behavior table) and
nix-darwin `modules/launchd/default.nix` (option→path mapping).

| Mechanism | nix-darwin option | Install path | launchd domain | Runs as | GUI / TCC | Runs w/o login | Job scope |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Daemon** | `launchd.daemons` | `/Library/LaunchDaemons` | `system` | root (or `UserName`) | **No** | **Yes** | system-wide |
| **Global agent** | `launchd.agents` | `/Library/LaunchAgents` | `gui` (per logged-in user) | each logged-in user | **Yes** | No | **all logged-in users** |
| **User agent** | `environment.userLaunchAgents` (a.k.a. `launchd.user.agents`) | `~/Library/LaunchAgents` | `gui/<uid>` | primary user | **Yes** | No | **primary user only** |

- **Only agents have GUI/TCC access.** Daemons run in the system domain with no
  user session, so they cannot receive TCC grants and cannot talk to GUI apps.
- **Global agents are still agents** — they run as the logged-in user and *do*
  have GUI/TCC. The recurring `launchctl` warning when nix-darwin loads a
  `/Library/LaunchAgents` plist is **not** a daemon/agent mismatch: it is an
  activation artifact. nix-darwin's `setupLaunchAgents` loads global-agent plists
  **as root**, and legacy `launchctl load` infers the target domain from the
  process EUID — root ⇒ `system` domain ⇒ mismatch ⇒ warning + `Load failed: 5`.
  nix-darwin then re-bootstraps into `gui/<uid>`, which succeeds.
- **User agents are loaded as the user** via
  `launchctl asuser <uid> sudo --user=<user> -- launchctl load -w ~<user>/Library/LaunchAgents/...`
  (same pattern nix-darwin uses for `org.nixos.gnupg-agent`). No root/system
  mismatch ⇒ **no warning**.
- All three nix-darwin options generate the plist via the **same**
  `toEnvironmentText` helper = `generators.toPlist { escape = true; }`. A plist
  built by hand with `lib.generators.toPlist { escape = true; }` is
  **byte-identical** to what `launchd.agents`/`launchd.daemons` would generate.

## Rule 1 — assume multi-user by default

**Never assume a host has a single user. Never special-case behavior for
single-user systems. Design for multiple concurrent users on every platform
(macOS, NixOS, Windows).**

The choice between daemon / global agent / user agent is driven by **what the
job needs and its scope**, never by how many users happen to exist on the box:

1. Needs to run with **no user logged in**, OR must **not** have GUI/TCC
   (security isolation), OR needs root-owned system resources → **daemon**
   (`launchd.daemons`).
2. Needs **GUI/TCC** AND must run for **every logged-in user** (all-user scope)
   → **global agent** (`launchd.agents`). On a multi-user Mac each user gets
   their own instance in their `gui/<uid>` domain.
3. Needs **GUI/TCC** AND is **scoped to the primary user** (tied to one user's
   home, config, or session) → **user launch agent**
   (`environment.userLaunchAgents`).

Mis-scoping an all-user job as a user agent silently drops it for other users on
a multi-user host. Conversely, assuming "single-user" to justify a global agent
is a wrong design assumption that breaks the moment a second user logs in.

## Rule 2 — prefer user launch agents

**Prefer `environment.userLaunchAgents` (user launch agents) over
`launchd.agents` (global agents) whenever the job is not provably all-user.**

Rationale: a user launch agent installs into `~/Library/LaunchAgents` and runs
in that user's `gui/<uid>` domain, so **each user can configure it
individually** (enable/disable, override the plist, scope it to their own home
and config). A global agent installs into `/Library/LaunchAgents` and runs for
every logged-in user with one shared definition — it removes per-user
configurability and, under nix-darwin, triggers the recurring root-domain
warning above.

Default to user launch agents. Reach for a global agent **only** when the job
genuinely must run for *every* logged-in user with identical behavior (e.g. a
system-wide accessibility helper that has no per-user configuration). When in
doubt, user launch agent.

## Plist generation for `environment.userLaunchAgents`

`environment.userLaunchAgents.<name>` takes raw `text` (a plist string), not a
`serviceConfig` attrset. Build it from the same attrset nix-darwin would have
generated:

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

This is byte-identical to the plist `launchd.agents` would emit, so behavior is
unchanged except install location (`/Library` → `~/Library`) and load context
(root → user). Standardize on `serviceConfig`-shaped attrsets (rename legacy
`config = { ... }` to the attrset form) before conversion.

## Related instruction files

- `programming-principles.instructions.md` — General coding principles.
- `macos-service-hardening.instructions.md` — SIP /bin/sh wrapper and TCC notes
  for macOS services.
- `cross-host-feature-parity.instructions.md` — NixOS `systemd.user.services` and
  Windows equivalents must mirror the macOS agent scope (user-scoped, not
  system-wide) for parity.
