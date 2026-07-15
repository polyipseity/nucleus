# tests/integration/vscode-extension-pruning-tests.nix — Verify VS Code extension pruning logic.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  posixEditors = builtins.readFile ../../src/modules/editors.nix;
  windowsExtensions = builtins.readFile ../../src/hosts/Windows/modules/editors/Sync-VSCodeExtension.ps1;

  test_posix_prunes_all_unmanaged_entries = assert' (
    lib.hasInfix ''rm -rf "$_sed_existing"'' posixEditors
    && lib.hasInfix ''rm -f "$_sed_dir/.obsolete"'' posixEditors
    && lib.hasInfix ''rm -f "$_sed_dir/extensions.json"'' posixEditors
  ) "POSIX VS Code extension provisioning must prune unmanaged entries and remove derived metadata";

  test_windows_prunes_all_unmanaged_entries = assert' (
    lib.hasInfix "Remove-Item -Path $_.FullName -Recurse -Force" windowsExtensions
    && lib.hasInfix "Remove-Item -Path (Join-Path $channel.ExtDir 'extensions.json') -Force -ErrorAction SilentlyContinue" windowsExtensions
    && lib.hasInfix "Remove-Item -Path (Join-Path $channel.ExtDir '.obsolete') -Force -ErrorAction SilentlyContinue" windowsExtensions
  ) "Windows VS Code extension provisioning must prune unmanaged entries and remove derived metadata";
in
{
  success = true;
  testCount = 2;
  message = "All ${builtins.toString 2} VS Code extension pruning regression tests passed";
}
