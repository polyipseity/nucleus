---
description: "Use when adding, editing, or reviewing launchd daemons/agents on macOS (nix-darwin), or porting equivalent systemd user services on NixOS/Windows. Covers the three mechanisms, multi-user-by-default rule, and user-launch-agent preference."
name: "launchd mechanism policy"
applyTo: "src/**/*.nix, src/platforms/macOS/**, src/hosts/MacBook/**, tests/**/*.nix"
---

# launchd mechanism policy (macOS / nix-darwin)

## The three mechanisms

Three distinct mechanisms with different domains, privileges, and lifecycles.
Source: Apple *Daemons and Services Programming Guide* /
[launchd.info](https://www.launchd.info/) (location→behavior table) and
nix-darwin `modules/launchd/default.nix` (option→path mapping).

| Mechanism | nix-darwin option | Install path | launchd domain | Runs as | GUI / TCC | Runs w/o login | Job scope |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Daemon** | `launchd.daemons` | `/Library/LaunchDaemons` | `system` | root (or `UserName`) | **No** | **Yes** | system-wide |
| **Global agent** | `launchd.agents` | `/Library/LaunchAgents` | `gui` (per logged-in user) | each logged-in user | **Yes** | No | **all logged-in users** |
| **User agent** | `environment.userLaunchAgents` (a.k.a. `launchd.user.agents`) | `~/Library/LaunchAgents` | `gui/<uid>` | primary user | **Yes** | No | **primary user only** |

- **Only agents have GUI/TCC access.** Daemons run in the system domain with no
  user session, so they cannot receive TCC grants or talk to GUI apps.
- **Global agents are still agents** — they run as the logged-in user and have
  GUI/TCC. The recurring `launchctl` warning when nix-darwin loads a
  `/Library/LaunchAgents` plist is not a daemon/agent mismatch: it is an
  activation artifact. nix-darwin's `setupLaunchAgents` loads global-agent plists
  as root, and legacy `launchctl load` infers the target domain from the
  process EUID — root ⇒ `system` domain ⇒ mismatch ⇒ warning + `Load failed: 5`.
  nix-darwin then re-bootstraps into `gui/<uid>`, which succeeds.
- **User agents are loaded as the user** via
  `launchctl asuser <uid> sudo --user=<user> -- launchctl load -w ~<user>/Library/LaunchAgents/...`
  (same pattern nix-darwin uses for `org.nixos.gnupg-agent`). No root/system
  mismatch ⇒ no warning.
- All three nix-darwin options generate the plist via the same
  `toEnvironmentText` helper = `generators.toPlist { escape = true; }`. A plist
  built by hand with `lib.generators.toPlist { escape = true; }` is
  byte-identical to what `launchd.agents`/`launchd.daemons` would generate.

## Rule 1 — assume multi-user by default

**Never assume a host has a single user. Never special-case behavior for
single-user systems. Design for multiple concurrent users on every platform.**

The choice between daemon / global agent / user agent is driven by what the
job needs and its scope, never by how many users exist on the box:

1. Needs to run with **no user logged in**, OR must **not** have GUI/TCC
   (security isolation), OR needs root-owned system resources → **daemon**
   (`launchd.daemons`).
2. Needs **GUI/TCC** AND must run for **every logged-in user** (all-user scope)
   → **global agent** (`launchd.agents`). On a multi-user Mac each user gets
   their own instance in their `gui/<uid>` domain.
3. Needs **GUI/TCC** AND is **scoped to the primary user** (tied to one user's
   home, config, or session) → **user launch agent**
   (`environment.userLaunchAgents`).

Mis-scoping an all-user job as a user agent silently drops it for other users.
Conversely, assuming "single-user" to justify a global agent breaks the moment
a second user logs in.

## Rule 2 — prefer user launch agents

**Prefer `environment.userLaunchAgents` over `launchd.agents` whenever the job
is not provably all-user.**

A user launch agent installs into `~/Library/LaunchAgents` and runs in that
user's `gui/<uid>` domain, so each user can configure it individually
(enable/disable, override the plist, scope it to their own home and config).
A global agent installs into `/Library/LaunchAgents` and runs for every
logged-in user with one shared definition — it removes per-user
configurability and, under nix-darwin, triggers the root-domain warning above.

Default to user launch agents. Use a global agent only when the job genuinely
must run for every logged-in user with identical behavior (e.g. a system-wide
accessibility helper). When in doubt, user launch agent.

### Activation-restart gap — use HM `launchd.agents` (domain = "user") for persistent daemons

`environment.userLaunchAgents` (nix-darwin top-level) only `launchctl load`s an
agent if it is NOT already loaded. It does not restart a loaded agent when
its plist (store hash in `ProgramArguments`) changes. A `KeepAlive` agent
keeps running the stale binary across every `nucleus-apply` until the user
logs out — the running process is never replaced. (camilladsp-heartbeat ran a
pre-fix binary for days after deploy.)

For any persistent user-scoped job (KeepAlive / Restart=always / long-lived
loop), declare it as Home Manager `launchd.agents.<name>` with `domain = "user"`
instead. HM's `setupLaunchAgents` does `cmp -s` and bootout+bootstrap on any
plist change, so a rebuild takes effect on the next apply with no manual
intervention. The install path (`~/Library/LaunchAgents`) and `gui/<uid>` domain
are identical, so TCC scope and per-user configurability are unchanged.

`environment.userLaunchAgents` remains valid only for the nix-darwin config
context (`hosts/MacBook/*.nix` imported via `MacBook/default.nix` `imports`)
where the job is genuinely short-lived or does not need restart-on-change. Do
not introduce new persistent `environment.userLaunchAgents` entries; migrate
existing ones to HM `launchd.agents` (domain = "user").

## Plist generation for `environment.userLaunchAgents`

`environment.userLaunchAgents.<name>` takes raw `text` (a plist string), not a
`serviceConfig` attrset. Build it from the same attrset nix-darwin would generate:

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
(root → user). Standardize on `serviceConfig`-shaped attrsets before conversion
(rename legacy `config = { ... }` to the attrset form).

## User agent in Home Manager modules

`environment.userLaunchAgents` is a nix-darwin top-level option. It is invalid
inside a Home Manager module (anything imported via `home.nix` or
`home-manager.sharedModules`) — the build fails with
`home-manager.users.<user>.environment does not exist`.

In HM module context, declare a user-scoped agent with HM's native
`launchd.agents.<name>` and `domain = "user"`. This installs the plist into
`~/Library/LaunchAgents` and registers it in the user domain (`gui/<uid>`),
same install path and no-warning load context as `environment.userLaunchAgents`:

```nix
launchd.agents."<name>" = {
  domain = "user";
  config = {
    Label = "local.<name>";
    ProgramArguments = [ "..." ];
    RunAtLoad = true;
  };
};
```

Use this form for every primaryUser-scoped agent defined in an HM module
(`src/platforms/macOS/modules/default.nix`, `src/modules/ext-discord-music-rpc.nix`,
`src/modules/cloud-drives.nix`). Reserve `environment.userLaunchAgents` for the
darwin config context (`src/hosts/MacBook/camilladsp.nix`, imported via
`MacBook/default.nix` `imports`).

## Related instruction files

- `programming-principles.instructions.md` — General coding principles.
- `macos-service-hardening.instructions.md` — SIP /bin/sh wrapper and TCC notes
  for macOS services.
- `cross-host-feature-parity.instructions.md` — NixOS `systemd.user.services` and
  Windows equivalents must mirror the macOS agent scope (user-scoped, not
  system-wide) for parity.
