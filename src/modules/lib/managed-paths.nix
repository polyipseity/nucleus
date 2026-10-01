# modules/lib/managed-paths.nix - Canonical declaration of managed PATH
# components and helpers.
#
# Mirrors ManagedPaths.ps1 (Windows); keep the two in sync.
# Takes only `pkgs`, no config, lib, or username dependency.
{ pkgs, ... }:
let
  lib = pkgs.lib;

  # Fallback toolchain for repos without direnv or a Nix devShell.
  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.prek
      pkgs.uv
    ];
  };

  # User-scoped `node` -> `bun` shim.  bun's node-compat mode runs Node.js
  # scripts, so a `node` symlink to `bun` resolves `node <script>` (inside
  # `bun run` child shells, GUI apps) without installing Node.js.  Installed
  # into ~/.local/bin, already on the managed append PATH, so subprocesses
  # resolve it.  Interactive `node()` in init.zsh still blocks: this is
  # infrastructure on PATH, not a licence to run node interactively.
  nodeShim = pkgs.runCommand "node-shim" { } ''
    mkdir -p "$out/bin"
    ln -s "${pkgs.bun}/bin/bun" "$out/bin/node"
  '';

  # Managed PATH directories, split into prepend (before the system default
  # PATH) and append (after it).  Consumers render each group as a
  # platform-appropriate PATH string.
  pathComponents = {
    prepend = [ ];
    append = [
      ".bun/bin"
      ".cargo/bin"
      ".local/bin"
    ];
  };

  # Named reference to the .cargo/bin rustup shim.  Consumers use this instead
  # of a hardcoded index into pathComponents.append.
  cargoBinDir = builtins.elemAt pathComponents.append 1;

  # Colon-joined absolute PATH string for `sudo launchctl config user path`.
  # Takes homeDir (e.g. "${config.home.homeDirectory}") and renders every
  # managed directory plus the system fallbacks.  Used by gui-env-path in
  # macos.nix.
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

  toShellPrependPath = builtins.concatStringsSep ":" (map (p: "$HOME/${p}") pathComponents.prepend);

  toShellAppendPath = builtins.concatStringsSep ":" (map (p: "$HOME/${p}") pathComponents.append);

  # Like toShellPrependPath but resolves the home directory at build time.
  # For launchd argv, where no shell expansion occurs because the `sh -c`
  # wrapper single-quotes its arguments.
  toAbsolutePrependPath =
    homeDir: builtins.concatStringsSep ":" (map (p: "${homeDir}/${p}") pathComponents.prepend);

  toAbsoluteAppendPath =
    homeDir: builtins.concatStringsSep ":" (map (p: "${homeDir}/${p}") pathComponents.append);

  # Expands to "<prepend>:" when prepend renders non-empty, "" otherwise.
  # Computed at Nix time because Nix cannot parse nested ${} inside a string
  # interpolation.
  toShellPrependGuard = lib.optionalString (toShellPrependPath != "") "${toShellPrependPath}:";

  toShellAppendGuard = lib.optionalString (toShellAppendPath != "") ":${toShellAppendPath}";

  # Complete PowerShell block that prepends every managed dir to $env:PATH with
  # existence (Test-Path) and dedup (notlike) guards.  Derived from
  # pathComponents.prepend, so a new dir needs one update only.  pwsh.nix renders
  # it into the HM-managed PowerShell profile.
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
    nodeShim
    pathComponents
    toAbsoluteAppendPath
    toAbsolutePrependPath
    toLaunchctlConfigPath
    toShellAppendGuard
    toShellAppendPath
    toShellPrependGuard
    toShellPrependPath
    toPowerShellAppendSnippet
    toPowerShellPrependSnippet
    ;
}
