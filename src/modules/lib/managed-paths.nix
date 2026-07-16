# modules/lib/managed-paths.nix — Canonical declaration of managed PATH
# components and related helpers.
#
# Mirrors ManagedPaths.ps1 (Windows) — keep the two files in sync.
#
# Takes only `pkgs` — no config, lib, or username dependency.
# Returns: { defaultDevTools, pathComponents, toShellPrependPath,
#   toShellAppendPath, toPowerShellPrependSnippet,
#   toPowerShellAppendSnippet, toLaunchctlPrependPath,
#   toLaunchctlAppendPath, nixProfileBinDirs, nixSystemBinDirs }
{
  pkgs,
  ...
}:
let
  # ── Fallback toolchain ──────────────────────────────────────────────
  # symlinkJoin of bun + prek + uv for repos without direnv/Nix devShell.
  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.prek
      pkgs.uv
    ];
  };

  # ── PATH components ─────────────────────────────────────────────────
  # Managed PATH directories split into prepend (before system default) and
  # append (after system default) groups.  Each consumer renders these as
  # platform-appropriate PATH strings.
  # Prepend: user-scope package manager bin directories.
  # Append: empty for now — reserved for future use.
  pathComponents = {
    prepend = [
      ".bun/bin"
      ".cargo/bin"
      ".local/bin"
    ];
    append = [ ];
  };

  # ── Helper: render macOS launchctl prepend PATH string ─────────────
  # Returns a colon-joined string of prepend dirs only for use as
  # __nucleus_prepend in macOS activation/LaunchAgent scripts.
  # Contains only the managed prepend dirs, no system default.
  # NOTE: Returns only managed prepend PATH components — callers must
  # combine with the runtime system PATH.
  toLaunchctlPrependPath = builtins.concatStringsSep ":" (
    map (p: "$HOME/${p}") pathComponents.prepend
  );

  # ── Helper: render macOS launchctl append PATH string ──────────────
  # Returns a colon-joined string of append dirs only for use as
  # __nucleus_append in macOS activation/LaunchAgent scripts.
  # Contains only the managed append dirs, no system default.
  # NOTE: Returns only managed append PATH components — callers must
  # combine with the runtime system PATH.
  toLaunchctlAppendPath = builtins.concatStringsSep ":" (map (p: "$HOME/${p}") pathComponents.append);

  # ── Helper: render generic shell PATH prepend string ───────────────
  # Same format as toLaunchctlPrependPath but with a generic name for use
  # in shell scripts that are not macOS-launchctl-specific.
  toShellPrependPath = builtins.concatStringsSep ":" (
    map (p: "$HOME/${p}") pathComponents.prepend
  );

  # ── Helper: render generic shell PATH append string ────────────────
  # Same format as toShellPrependPath but for the append position.
  toShellAppendPath = builtins.concatStringsSep ":" (
    map (p: "$HOME/${p}") pathComponents.append
  );

  # ── Helper: render PowerShell PATH-prepend snippet ─────────────────
  # Returns a complete PowerShell block that prepends all managed dirs to
  # $env:PATH with existence guards (Test-Path) and dedup guards (notlike).
  # Derived from pathComponents.prepend — additions need only one update.
  # Used by pwsh.nix to generate the HM-managed PowerShell profile.
  toPowerShellPrependSnippet = let
    entries = builtins.map (p: builtins.replaceStrings [ "/" ] [ "\\" ] p) pathComponents.prepend;
    entriesStr = builtins.concatStringsSep ",\n      " (
      builtins.map (entry: "(Join-Path $HOME \"${entry}\")") entries
    );
  in ''
    $__nucleusBinPaths = @(
      ${entriesStr}
    )
    foreach ($__nucleusBinPath in $__nucleusBinPaths) {
      if ((Test-Path $__nucleusBinPath) -and ($env:PATH -notlike "*$__nucleusBinPath*")) {
        $env:PATH = "$__nucleusBinPath;$env:PATH"
      }
    }
    Remove-Variable __nucleusBinPaths, __nucleusBinPath -ErrorAction SilentlyContinue
  '';

  # ── Helper: render PowerShell PATH-append snippet ──────────────────
  # Same structure as toPowerShellPrependSnippet but appends to PATH
  # instead of prepending.  Derived from pathComponents.append.
  toPowerShellAppendSnippet = let
    entries = builtins.map (p: builtins.replaceStrings [ "/" ] [ "\\" ] p) pathComponents.append;
    entriesStr = builtins.concatStringsSep ",\n      " (
      builtins.map (entry: "(Join-Path $HOME \"${entry}\")") entries
    );
  in ''
    $__nucleusBinPaths = @(
      ${entriesStr}
    )
    foreach ($__nucleusBinPath in $__nucleusBinPaths) {
      if ((Test-Path $__nucleusBinPath) -and ($env:PATH -notlike "*$__nucleusBinPath*")) {
        $env:PATH = "$env:PATH;$__nucleusBinPath"
      }
    }
    Remove-Variable __nucleusBinPaths, __nucleusBinPath -ErrorAction SilentlyContinue
  '';

  # ── Helper: Nix profile probe directories ─────────────────────────
  # Shell-quoted list of Nix/home-manager profile bin directories probed by
  # _nucleus_prepend_first_executable_dir in activation steps.
  # Contains $HOME references — expanded at shell runtime, not by Nix.
  nixProfileBinDirs = ''
    "$HOME/.local/state/nix/profiles/profile/bin" \
    "$HOME/.nix-profile/bin" \
    "$HOME/.local/state/home-manager/profile/bin" \
    "$HOME/.local/home-manager/profile/bin"
  '';

  # ── Helper: NixOS system profile probe directories ────────────────
  # Shell-quoted list of NixOS system-wide profile bin directories.
  # Contains $USER reference — expanded at shell runtime, not by Nix.
  nixSystemBinDirs = ''
    "/etc/profiles/per-user/$USER/bin" \
    "/run/current-system/sw/bin"
  '';
in
{
  inherit
    defaultDevTools
    pathComponents
    toLaunchctlPrependPath
    toLaunchctlAppendPath
    toShellPrependPath
    toShellAppendPath
    toPowerShellPrependSnippet
    toPowerShellAppendSnippet
    nixProfileBinDirs
    nixSystemBinDirs
    ;
}
