---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

Install tools and libraries at user level. System-wide installs are limited to infrastructure: nix-darwin `environment.systemPackages`, the NixOS system config, and the WinGet DSC registry. Python uses `uv tool install`, never `pip install --system`; Rust uses devShell then `cargo-binstall` then `cargo install` into `~/.cargo/bin`; JS uses `bun install -g`, never `npm install -g`.

System-install-only tools are not for interactive dev use: `bun`, `cargo`, `rustup`, `uv`, `prek`; `python`/`pip` and `npm`/`npx`/`node`/`corepack` are banned. Blocked tools are shell functions that check `$DIRENV_DIR` and redirect to devShell; POSIX `init.zsh` and PowerShell `profile.ps1` share the set. PATH goes through `home.sessionPath`.

`managedPackages` in `src/modules/core.nix` is the single declared registry, sorted by name; `platforms` gates nixpkgs and Homebrew carriers, never WinGet ids. No duplicate of a registry package in host files. A tap-qualified Homebrew formula requires uninstalling it on every MacBook before dropping the tap; no migration shim.

Violations and full tables: `.agents/skills/nucleus-policy-reference/references/package-installation-scope.md`.
