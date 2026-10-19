# modules/posix/toolchain-links.nix: Converge the SYSTEM-root toolchain symlink
# farm each apply.
#
# The env catalog exports stable paths under `<SYSTEM root>/toolchains/<name>` on
# both POSIX hosts instead of raw /nix/store derivations, so a rebuild plus GC
# cannot leave an inherited CC/DEVELOPER_DIR/SDKROOT pointing at a freed path.
# Interpolating the targets here is what pins them into the system closure: the
# links stay resolvable for as long as this generation is live.
{
  lib,
  pkgs,
  hostName,
  ...
}:
let
  activationBundle = pkgs.callPackage ../lib/script-tree.nix { };
  toolchainLinks = import ../lib/toolchain-links.nix { inherit lib pkgs; };
  # The targets are derivations; coerce each to its store-path string before
  # toJSON, which would otherwise try to serialize the derivation attrset.
  targetsJson = builtins.toJSON (
    builtins.mapAttrs (_name: target: "${target}") (toolchainLinks.linkTargetsFor hostName)
  );
  convergeToolchainLinks = ''
    "${activationBundle}/src/scripts/configs/converge-toolchain-links.sh" \
      "${pkgs.jq}/bin/jq" \
      "${toolchainLinks.linkDirFor hostName}" \
      '${targetsJson}'
  '';
in
{
  # postActivation is the one fragment name nix-darwin honours and NixOS also
  # runs as a named activation script, so one entry covers both platforms.
  system.activationScripts.postActivation.text = lib.mkAfter convergeToolchainLinks;
}
