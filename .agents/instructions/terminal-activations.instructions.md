---
description: "Use when adding or editing terminal activation entries in Nix or PowerShell files. Covers the last-resort policy for nucleus.terminalActivations, when it is acceptable, and the required WHY-comment at every call site."
name: "Terminal Activations Policy"
applyTo: "src/**/*.nix, src/**/*.ps1"
---

# Terminal activations — last resort policy

Terminal activations (`nucleus.terminalActivations`) are a **LAST RESORT**.
Never add a new entry unless **all three** criteria are met:

1. **TCC constraint**: the command MUST run in the user's terminal context (outside sudo/Nix activation) — typically because macOS TCC grants (Full Disk Access, Accessibility) are required and would be lost inside the sudo process tree during `darwin-rebuild switch`.
2. **No alternative**: the command cannot be refactored into a Nix declarative option, a Home Manager activation entry, or a system activation script that runs inside the rebuild.
3. **Documented constraint**: the technical constraint is documented inline with a `# WHY: terminal-activations (last resort):` comment at the call site.

If a command does not need TCC-sensitive context (FDA, Accessibility, Screen Recording, Automation), it **SHOULD** run as a normal Nix/Home Manager activation entry. Terminal activations are inherently imperative (eval'd from a text file) and bypass the declarative Nix model — each use erodes reproducibility.

## Call site requirements

Every `nucleus.terminalActivations` entry in `.nix` files must have a `# WHY: terminal-activations (last resort):` comment immediately before it, explaining why the Nix activation path cannot work for that specific command.

## Rationale

macOS `darwin-rebuild switch` runs as root (via sudo). Activation scripts executing inside that process tree lose macOS TCC grants (Full Disk Access, Accessibility, Screen Recording, Automation). Terminal activations escape the sudo process tree, so TCC grants are inherited from the user's shell session.

This is a macOS-specific limitation. On Linux and Windows, there is no TCC concept — if a terminal activation is added for a non-macOS host, it must have an equally compelling reason documented.

## Reference

See `src/modules/terminal-activations.nix` for the canonical module definition and policy text.
