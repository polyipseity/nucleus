---
description: "Use when adding, editing, or reviewing launchd daemons/agents on macOS (nix-darwin), or porting equivalent systemd user services on NixOS/Windows. Covers the three mechanisms, multi-user-by-default rule, and user-launch-agent preference."
name: "launchd mechanism policy"
applyTo: "src/**/*.nix, src/platforms/macOS/**, src/hosts/MacBook/**, tests/**/*.nix"
---

# launchd mechanism policy

Three mechanisms: daemon (`launchd.daemons`, `/Library/LaunchDaemons`, system domain, root or `UserName`, no GUI, runs without login), global agent (`launchd.agents`, `/Library/LaunchAgents`, `gui` domain, every logged-in user), and user agent (`environment.userLaunchAgents`, `~/Library/LaunchAgents`, `gui/<uid>`, primary user). Assume multi-user by default: no GUI or root resources means daemon, every-user GUI/TCC means global agent, primary-user GUI/TCC means user agent. Prefer user agents and use global agents only for identical work for every user.

Persistent jobs belong in Home Manager `launchd.agents.<name>` with `domain = "gui"`, because `environment.userLaunchAgents` only loads a job not already loaded, leaving a stale `KeepAlive` binary until logout. HM `setupLaunchAgents` compares plists and bootstraps on change. `environment.userLaunchAgents` is nix-darwin top level and invalid inside HM modules; reserve it for short-lived jobs.

Source evidence, the load warning, and config shapes: `.agents/skills/nucleus-platform-reference/references/launchd.md`.
