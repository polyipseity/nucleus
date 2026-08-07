# src/modules/lib/scripts-bundle.nix — Single derivation bundling all user-facing
# CLIs from scripts/ at $out/scripts/. Consumed by writeNucleusShellApplication
# when bundleDefault = true (symlinked into app $out) or for per-script symlinks
# when bundleDefault = false and scriptName starts with scripts/.
{ pkgs }:

pkgs.runCommand "nucleus-scripts-bundle"
  {
    preferLocalBuild = true;
  }
  ''
    mkdir -p "$out"
    cp -r "${../../../scripts}" "$out/scripts"
    chmod -R +x "$out/scripts"
  ''
