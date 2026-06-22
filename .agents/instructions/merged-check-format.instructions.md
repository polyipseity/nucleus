---
description: "Use when modifying the repo-check / format-nix merged pre-commit hook setup."
name: "Merged Nix check-and-format hook"
applyTo: "prek.toml, scripts/check.sh, scripts/prek-hooks.py"
---

- `check.sh` accepts `--format` to format Nix files in-place (nixfmt -s) vs just validating (nixfmt -s --verify).
- Nix formatting is opt-in. `prek-hooks.py` passes `--format` to `check.sh` only when invoked with `--format` (configured via `args = ["--format"]` in `prek.toml`).
- `prek.toml` has a single `repo-check` hook with `files = "(\\\\.sh|\\\\.ps1|\\\\.pkr\\\\.hcl|\\\\.nix)$"` — note TOML escaping: `\\\\.` → regex `\\.`
- `nixfmt` is bundled in `mkCheckApp` `runtimeInputs` in `src/flake.nix`, avoiding expensive nixpkgs eval.
- No separate `format-nix` hook exists.
