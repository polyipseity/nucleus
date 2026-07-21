# modules/lib/managed-paths.nix — Canonical declaration of managed PATH
# components and related helpers.
#
# Mirrors ManagedPaths.ps1 (Windows) — keep the two files in sync.
#
# Takes only `pkgs` — no config, lib, or username dependency.
# Returns: { defaultDevTools, pathComponents, cargoBinDir,
#   toShellPrependPath, toShellAppendPath, toShellPrependGuard,
#   toShellAppendGuard, toPowerShellPrependSnippet,
#   toPowerShellAppendSnippet, toLaunchctlConfigPath }
{ pkgs, ... }:
let
  lib = pkgs.lib;

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
  # Prepend: directories that appear before the system default PATH.
  # Append: directories that appear after the system default PATH.
  pathComponents = {
    prepend = [ ];
    append = [
      ".bun/bin"
      ".cargo/bin"
      ".local/bin"
    ];
  };

  # Named reference: .cargo/bin (rustup shim).  Consumers must use this instead
  # of hardcoded indices into pathComponents.append.
  cargoBinDir = builtins.elemAt pathComponents.append 1;

  # ── Helper: render launchctl config user path string ───────────────
  # Returns a colon-joined absolute PATH string for use in
  # sudo launchctl config user path.  Takes homeDir as an argument
  # (e.g. "${config.home.homeDirectory}") and renders all managed
  # directories as absolute paths including system fallbacks.
  # Used by gui-env-path in macos.nix.
  toLaunchctlConfigPath =
    homeDir:
    let
      username = builtins.baseNameOf homeDir;
    in
    builtins.concatStringsSep ":" (
      (map (p: "${homeDir}/${p}") pathComponents.prepend)
      ++ (map (p: "${homeDir}/${p}") pathComponents.append)
      ++ [
        "${homeDir}/.local/state/nix/profiles/profile/bin"
        "${homeDir}/.nix-profile/bin"
        "${homeDir}/.local/state/home-manager/profile/bin"
        "${homeDir}/.local/home-manager/profile/bin"
        "/etc/profiles/per-user/${username}/bin"
        "/run/current-system/sw/bin"
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
      ]
    );

  # ── Helper: render generic shell PATH prepend string ───────────────
  # Same format as toShellPrependPath but for the append position.
  toShellPrependPath = builtins.concatStringsSep ":" (map (p: "$HOME/${p}") pathComponents.prepend);

  # ── Helper: render generic shell PATH append string ────────────────
  # Same format as toShellPrependPath but for the append position.
  toShellAppendPath = builtins.concatStringsSep ":" (map (p: "$HOME/${p}") pathComponents.append);

  # ── Helper: shell prepend guard (:suffix) ─────────────────────────
  # Expands to "<prepend>:" when prepend renders non-empty, empty string
  # otherwise.  Computed at Nix time to avoid nested ${} in Nix string
  # interpolation (which Nix cannot parse).
  toShellPrependGuard = lib.optionalString (toShellPrependPath != "") "${toShellPrependPath}:";

  # ── Helper: shell append guard (:prefix) ──────────────────────────
  # Expands to ":<append>" when append renders non-empty, empty string
  # otherwise.  Computed at Nix time to avoid nested ${} in Nix string
  # interpolation (which Nix cannot parse).
  toShellAppendGuard = lib.optionalString (toShellAppendPath != "") ":${toShellAppendPath}";

  # ── Helper: render PowerShell PATH-prepend snippet ─────────────────
  # Returns a complete PowerShell block that prepends all managed dirs to
  # $env:PATH with existence guards (Test-Path) and dedup guards (notlike).
  # Derived from pathComponents.prepend — additions need only one update.
  # Used by pwsh.nix to generate the HM-managed PowerShell profile.
  toPowerShellPrependSnippet =
    let
      entries = builtins.map (p: builtins.replaceStrings [ "/" ] [ "\\" ] p) pathComponents.prepend;
      entriesStr = builtins.concatStringsSep ",\n      " (
        builtins.map (entry: "(Join-Path $HOME \"${entry}\")") entries
      );
    in
    ''
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
  toPowerShellAppendSnippet =
    let
      entries = builtins.map (p: builtins.replaceStrings [ "/" ] [ "\\" ] p) pathComponents.append;
      entriesStr = builtins.concatStringsSep ",\n      " (
        builtins.map (entry: "(Join-Path $HOME \"${entry}\")") entries
      );
    in
    ''
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

in
{
  inherit
    cargoBinDir
    defaultDevTools
    pathComponents
    toLaunchctlConfigPath
    toShellAppendGuard
    toShellAppendPath
    toShellPrependGuard
    toShellPrependPath
    toPowerShellAppendSnippet
    toPowerShellPrependSnippet
    ;
}
