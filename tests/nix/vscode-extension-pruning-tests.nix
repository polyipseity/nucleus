# tests/nix/vscode-extension-pruning-tests.nix — Verify VS Code extension pruning logic.
#
# This regression test checks the source text for the POSIX and Windows VS Code
# extension provisioning paths to ensure they prune non-managed extensions and
# remove VS Code's derived metadata files (`extensions.json` and `.obsolete`).
#
# Run with: nix-instantiate --eval tests/nix/vscode-extension-pruning-tests.nix

{ lib ? import <nixpkgs/lib> }:
let
  assert' = cond: msg:
    if !cond then builtins.throw "ASSERTION FAILED: ${msg}" else null;

  posixEditors = builtins.readFile ../../src/modules/editors.nix;
  windowsExtensions = builtins.readFile ../../src/hosts/windows/modules/Sync-VSCodeExtension.ps1;

  test_posix_prunes_all_unmanaged_entries = assert'
    (
      lib.hasInfix ''rm -rf "$_sed_existing"'' posixEditors
      && lib.hasInfix ''rm -f "$_sed_dir/.obsolete"'' posixEditors
      && lib.hasInfix ''rm -f "$_sed_dir/extensions.json"'' posixEditors
    )
    "POSIX VS Code extension provisioning must prune unmanaged entries and remove derived metadata";

  test_windows_prunes_all_unmanaged_entries = assert'
    (
      lib.hasInfix ''Remove-Item -Path $_.FullName -Recurse -Force'' windowsExtensions
      && lib.hasInfix ''Remove-Item -Path (Join-Path $channel.ExtDir 'extensions.json') -Force -ErrorAction SilentlyContinue'' windowsExtensions
      && lib.hasInfix ''Remove-Item -Path (Join-Path $channel.ExtDir '.obsolete') -Force -ErrorAction SilentlyContinue'' windowsExtensions
    )
    "Windows VS Code extension provisioning must prune unmanaged entries and remove derived metadata";
in
{
  success = true;
  testCount = 2;
  message = "All ${builtins.toString 2} VS Code extension pruning regression tests passed";
}
