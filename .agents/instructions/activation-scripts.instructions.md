---
description: "Use when adding or editing activation scripts in Nix modules. Covers the seven acceptable styles (1-7), prohibited patterns, the string interpolation preference rule, and quality-of-life conventions."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix"
---

## Acceptable styles

Every activation block in this repo must use exactly one of these seven styles. No mixing, no hybrids.

### Style 1 — pure inline (string literal)

```nix
activation-block = lib.hm.dag.entry<Phase> [ "dependency" ] ''
  mkdir -p "$HOME/some-dir"
'';
```

**Only for very simple scripts**: at most 2-3 lines, no conditional logic, no loops, no external tool dependencies. Anything more complex must use Style 2, 3, or 4.

### Style 2 — inline string with embedded `readFile` calls

```nix
activation-block = lib.hm.dag.entry<Phase> [ "dependency" ] ''
  ${builtins.readFile ../scripts/lib/some-lib.sh}
  some_function ${lib.escapeShellArg arg1} "${arg2}" ${toString arg3}
'';
```

The canonical library-backed pattern. One or more `${builtins.readFile ...}` expressions are interpolated inside a single `''…''` string, optionally followed by inline function calls with Nix-interpolated arguments.

Rules:
- **Read the library only.** Never read a wrapper — always read the canonical lib under `src/scripts/lib/`.
- **Keep calls minimal.** One or two lines per function call. For complex logic (loops, conditionals, file ops), keep a standalone script.
- **No shebang.** Activation blocks are sourced fragments inside `set -eu` shell; do not add `#!/usr/bin/env bash`.
- **No SCRIPT_DIR / `.` sourcing.** Library functions are embedded directly via `builtins.readFile`.
- **`lib.escapeShellArg`** for Nix values going into shell single-quoted context. Use double quotes for simple store paths (`"${pkgs.jq}/bin/jq"`).
- **`$HOME` preserved.** In Nix `''` strings, `$` passes literally unless followed by `{`. `$HOME` works at runtime.

### Style 3 — bare `builtins.readFile`

```nix
activation-block = lib.hm.dag.entry<Phase> [ "dependency" ] (
  builtins.readFile ../scripts/some-script.sh
);
```

No outer string interpolation — the `readFile` result is returned directly. Use when the script needs **no Nix-valued data** injected.

### Style 4 — `replaceStrings` standalone script

```nix
activation-block = lib.hm.dag.entry<Phase> [ "dependency" ] (
  builtins.replaceStrings [ "__TOKEN__" ] [ "${nixValue}" ] (
    builtins.readFile ../scripts/some-script.sh
  )
);
```

For standalone scripts that need Nix-valued data injected via tokens. The `.sh` file must contain only the shell code with `__TOKEN__` placeholders — no inline shell appended in the Nix expression.

Token naming: use `__SCREAMING_SNAKE_CASE__` with double-underscore delimiters.

### Style 5 — `pkgs.writeShellScript` wrapper

```nix
someScript = pkgs.writeShellScript "script-name" (
  builtins.replaceStrings [ "__TOKEN__" ] [ "${nixValue}" ] (
    builtins.readFile ../scripts/some-script.sh
  )
);
```

Required when the consumer needs an **executable store path** (launchd `ProgramArguments`, systemd `ExecStart`, cron jobs, direct execution). The body follows Style 3 or 4 patterns inside the `writeShellScript` call. When no token substitution is needed, use bare `builtins.readFile`.

### Style 6 — `pkgs.writeTextFile` executable

```nix
someScript = pkgs.writeTextFile {
  name = "script-name";
  executable = true;
  text = ''
    #!${pkgs.bash}/bin/bash
    set -eu
    ${builtins.readFile ../scripts/lib/some-lib.sh}
    some_function "${arg}"
  '';
};
```

Same as Style 5, but with explicit shebang/header control. Only when the executable needs a specific shebang or header prefix not provided by `writeShellScript`. Must use `${...}` interpolation, never `+` concatenation.

### Style 7 — system megascript seam

Only for nix-darwin `system.activationScripts.postActivation.text` / `extraActivation.text` or NixOS `system.activationScripts.<name>` concatenation, where the Nix evaluation model requires multiple scripts to be assembled into **one string** (nix-darwin's fixed hardcoded activation script list). Each constituent fragment embedded via `${builtins.readFile ...}` must itself conform to one of Styles 1-6.

### Exception documentation

Every exception to these style rules must have an inline `# WHY` comment in the Nix expression explaining the technical constraint that prevents using an acceptable style.

---

## String interpolation, not concatenation

Within Nix expressions for activation bodies, always use `${...}` string interpolation rather than `+` string concatenation to combine string parts. Concatenation makes the data flow harder to trace and produces implicit evaluation order dependencies.

**Correct (interpolation):**

```nix
text = ''
  ${builtins.readFile ./lib.sh}
  some_function "${arg}"
'';
```

**Incorrect (concatenation):**

```nix
text = ''
  #!${bash}/bin/bash
  set -eu
''
+ (builtins.readFile ./lib.sh)
+ ''
  some_function "${arg}"
'';
```

This rule applies to all activation-related bodies: `home.activation.<name>`, `system.activationScripts.*.text`, `pkgs.writeTextFile.text`, `pkgs.writeShellScript` arguments, and any other script-producing expression.

---

## Prohibited patterns

- **No string concatenation (`+ ''...''` or `) + (builtins.readFile ...)`) in activation bodies** — use `${...}` interpolation inside a single `''…''` string instead.
- **No runtime `sh` invocation of an external script path** — embed the script content via `builtins.readFile` (Style 3/4).
- **No wrapper scripts that only source a lib and call functions** — inline the lib read and function call (Style 2).
- **No outer string wrapping a `replaceStrings` readFile** — the `replaceStrings` expression returns a string; return it directly (Style 4), don't wrap in `''...''`.
- **No inline Python invocation** — create a wrapper script (Style 3/4) that invokes Python.
- **No env vars as data-passing shim** — never `export VAR="${expr}"` before `readFile`. Use `builtins.replaceStrings` with `__TOKEN__` placeholders instead.

---

## Standalone scripts — Styles 3 and 4 (for complex logic)

When a script has substantive logic beyond sourcing + calling (loops, conditionals, file operations, error handling), keep it as a standalone `.sh` under `src/scripts/`:

- **Style 4** (with Nix-valued arguments via `replaceStrings`):
  ```nix
  builtins.replaceStrings [tokens] [values] (builtins.readFile ./script.sh)
  ```
- **Style 3** (no Nix-valued arguments needed — bare `readFile`):
  ```nix
  builtins.readFile ./script.sh
  ```

Standalone scripts are also required when:
- Shebang needed (launchd agents, cron jobs, direct execution)
- Used outside activation blocks (e.g., launchd `ProgramArguments`)
- Sources a lib AND has substantive logic beyond the function call

### Scripts must resolve dependencies relative to themselves via `SCRIPT_DIR`

Never reference `$REPO_ROOT` at runtime. The SCRIPT_DIR pattern:

```bash
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
```

This rule does not apply to scripts that are inlined via `builtins.readFile` — they use no `SCRIPT_DIR` at all.
