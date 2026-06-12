---
description: "Use when creating or modifying any provisioned symlink across all hosts (macOS, NixOS, Windows). Enforces consistent symlink semantics: writable + delete-protected by default, read-only when targeting Nix store, documented exceptions."
name: "Provisioned Symlink Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Provisioned Symlink Policy

## Default Rule

Every provisioned symlink must be **writable** AND **delete-protected**.

- **Delete-protection mechanism**: `chflags uchg` (macOS), `chattr +i` (Linux),
  `icacls /deny` (Windows). Best-effort with warning on failure.

## Read-Only Exception

A symlink MUST be read-only when its target is in the Nix store (or on Windows,
when the corresponding POSIX symlink uses a Nix store target). The Nix store
target is immutable, making the content effectively read-only.

## Deviation Rule

Any deviation from the default or read-only exception must be documented with:

1. A `# WHY` comment at the creation site.
2. An entry in the exceptions list below with full rationale.

## Cross-Platform Parity

When a symlink exists on both POSIX and Windows, writability semantics MUST
match. A read-only symlink on POSIX (Nix store target) must be made read-only
on Windows (read-only attribute or restrictive ACL).

## Known Exceptions

| Symlink | Reason | Platform |
|---|---|---|
| `~/.config/discord-music-rpc/config.yaml` | discord-music-rpc overwrites config on startup; read-only target prevents app from discarding managed settings | POSIX + Windows |
