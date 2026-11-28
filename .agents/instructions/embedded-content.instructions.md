---
description: "Use when embedding or extracting file content in Nix, shell, or PowerShell scripts."
name: "Embedded Content Policy"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/hosts/Windows/**/*.yml, src/scripts/**, src/vms/**, scripts/**"
---

# Embedded content policy

File content (templates, profiles, start scripts, wrappers, Caddyfiles, READMEs) lives in dedicated files on every platform, never script string literals. Exceptions need `# check-suppress:embedded-content:` at the call site. Tokens are `__UPPER_SNAKE__`; `{{TOKEN}}` is banned, every token is replaced or has a default, and comments never carry token markers.

The five exception classes are generated content, static content under 10 lines, C# interop up to 25 lines, split static/dynamic wrappers, and DSC Script Get/Test/Set of 1-3 lines. Structured data passed as parameters is exempt. Shared content uses one file when language and purpose match.

Platform read paths, token mechanisms, the shared-file registry, and lint wiring: `src/users/default/agents/skills/nucleus-citation-reference/references/embedded-content.md`.
