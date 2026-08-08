# src/modules/lib/script-tree.nix — Single derivation bundling scripts for activation
# and writeNucleusShellApplication wrappers. Bundles:
#   - src/scripts/ (cross-host POSIX)
#   - src/platforms/ (platform activation scripts)
#   - src/hosts/<Host>/scripts/ (host-only activation scripts; selective, not full hosts tree)
# The $out/ layout mirrors the repo root under $out/src/, making paths repo-root-relative.
# Shellcheck runs in nucleus-check-sh / CI, not at derivation build time.
{ pkgs }:

pkgs.runCommand "nucleus-script-tree"
  {
    preferLocalBuild = true;
  }
  ''
    mkdir -p "$out/src"
    cp -r "${../../../src/scripts}" "$out/src/scripts"
    if [ -d "${../../../src/platforms}" ]; then
      cp -r "${../../../src/platforms}" "$out/src/platforms"
    fi
    for hostScripts in ${../../../src}/hosts/*/scripts; do
      if [ -d "$hostScripts" ]; then
        host="$(basename "$(dirname "$hostScripts")")"
        mkdir -p "$out/src/hosts/$host"
        cp -r "$hostScripts" "$out/src/hosts/$host/scripts"
      fi
    done
    chmod -R +x "$out"
  ''
