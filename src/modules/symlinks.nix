# Per-user symlinks with per-host targets.
args@{
  config,
  lib,
  pkgs,
  ...
}:
let
  users = args.users or { };
  currentUsername = config.home.username;
  currentUserHome = config.home.homeDirectory;
  userConfig = users.${currentUsername}.symlinks or [ ];

  hostKey =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "MacBook"
    else if pkgs.stdenv.hostPlatform.isLinux then
      "NixOS"
    else
      null;

  nucleusUserRoot =
    if hostKey == "MacBook" then
      "${currentUserHome}/Library/Application Support/nucleus"
    else
      "${currentUserHome}/.local/share/nucleus";

  resolveManagedTargetPath =
    path:
    if path == null then
      null
    else if path == "~" then
      currentUserHome
    else if lib.hasPrefix "~/" path then
      "${currentUserHome}/${lib.removePrefix "~/" path}"
    else if lib.hasPrefix "/" path then
      path
    else
      "${currentUserHome}/${path}";

  targetForEntry =
    entry:
    if hostKey == null || !(entry ? targets) || !builtins.isAttrs entry.targets then
      null
    else if builtins.hasAttr hostKey entry.targets then
      entry.targets.${hostKey}
    else
      null;

  selectedSymlinksResolved =
    map
      (entry: {
        createTargetDirectory = entry.createTargetDirectory or false;
        linkAbsolutePath = "${currentUserHome}/${entry.path}";
        path = entry.path;
        targetAbsolutePath = resolveManagedTargetPath (targetForEntry entry);
      })
      (
        builtins.filter (
          entry:
          let
            target = targetForEntry entry;
          in
          target != null && target != ""
        ) config.nucleus.symlinks
      );

  managedSymlinkManifestPath = "${nucleusUserRoot}/symlinks.json";
  managedSymlinkManifestJson = builtins.toJSON (
    map (entry: entry.linkAbsolutePath) selectedSymlinksResolved
  );

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  options.nucleus.symlinks = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          createTargetDirectory = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create the selected host target directory before linking.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            description = "Symlink path relative to the managed user's home directory (for example 'data').";
          };
          targets = lib.mkOption {
            type = lib.types.submodule {
              options = {
                MacBook = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "MacBook target path for this symlink, absolute or relative to the managed user's home directory.";
                };
                NixOS = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "NixOS target path for this symlink, absolute or relative to the managed user's home directory.";
                };
                Windows = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Windows target path for this symlink; consumed by the Windows apply modules using the same user-registry schema.";
                };
              };
            };
            default = { };
            description = "Per-host symlink target map. Leave hosts null when the symlink should not exist there.";
          };
        };
      }
    );
    default = userConfig;
    description = "Per-user symlinks whose targets can differ by host. Empty by default.";
  };

  config = {
    home.file = builtins.listToAttrs (
      map (entry: {
        name = entry.path;
        value.source = config.lib.file.mkOutOfStoreSymlink entry.targetAbsolutePath;
      }) selectedSymlinksResolved
    );

    home.activation.ensure-symlink-targets = lib.hm.dag.entryBefore [ "prepare-symlinks" ] ''
      "${activationBundle}/src/scripts/configs/ensure-symlink-targets.sh" \
        "${managedSymlinkManifestPath}" \
        '${
          builtins.toJSON (
            map (entry: entry.linkAbsolutePath) (
              builtins.filter (entry: entry.createTargetDirectory) selectedSymlinksResolved
            )
          )
        }' \
        "${pkgs.jq}/bin/jq"
    '';

    home.activation.prepare-symlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/provision-symlinks.sh" \
        "${managedSymlinkManifestPath}" \
        "${pkgs.jq}/bin/jq" \
        '${managedSymlinkManifestJson}'
    '';

    home.activation.finalize-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/finalize-symlinks.sh" \
        "${managedSymlinkManifestPath}" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON (map (entry: entry.linkAbsolutePath) selectedSymlinksResolved)}' \
        '${managedSymlinkManifestJson}'
    '';
  };
}
