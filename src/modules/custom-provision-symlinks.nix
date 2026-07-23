# Per-user symlinks with platform-specific targets.
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
  userConfig = users.${currentUsername}.customProvisionSymlinks or [ ];

  platformKey =
    if pkgs.stdenv.isDarwin then
      "macos"
    else if pkgs.stdenv.isLinux then
      "linux"
    else
      null;

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
    if platformKey == null || !(entry ? targets) || !builtins.isAttrs entry.targets then
      null
    else if builtins.hasAttr platformKey entry.targets then
      entry.targets.${platformKey}
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
        ) config.nucleus.customProvisionSymlinks
      );

  managedSymlinkManifestPath = "${currentUserHome}/.config/nucleus/custom-provision-symlinks.json";
  managedSymlinkManifestJson = builtins.toJSON (
    map (entry: entry.linkAbsolutePath) selectedSymlinksResolved
  );

  activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };
in
{
  options.nucleus.customProvisionSymlinks = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          createTargetDirectory = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create the selected platform target directory before linking.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            description = "Symlink path relative to the managed user's home directory (for example 'data').";
          };
          targets = lib.mkOption {
            type = lib.types.submodule {
              options = {
                linux = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Linux target path for this symlink, absolute or relative to the managed user's home directory.";
                };
                macos = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "macOS target path for this symlink, absolute or relative to the managed user's home directory.";
                };
                windows = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Windows target path for this symlink; consumed by the Windows apply modules using the same user-registry schema.";
                };
              };
            };
            default = { };
            description = "Per-platform symlink target map. Leave platforms null when the symlink should not exist there.";
          };
        };
      }
    );
    default = userConfig;
    description = "Per-user custom symlinks whose targets can differ by platform. Empty by default.";
  };

  config = {
    home.file = builtins.listToAttrs (
      map (entry: {
        name = entry.path;
        value.source = config.lib.file.mkOutOfStoreSymlink entry.targetAbsolutePath;
      }) selectedSymlinksResolved
    );

    home.activation.ensureCustomProvisionSymlinkTargets =
      lib.hm.dag.entryBefore [ "prepareCustomProvisionSymlinks" ]
        ''
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

    home.activation.prepareCustomProvisionSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/provision-symlinks.sh" \
        "${managedSymlinkManifestPath}" \
        "${pkgs.jq}/bin/jq"
    '';

    home.activation.finalizeCustomProvisionSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/finalize-symlinks.sh" \
        "${managedSymlinkManifestPath}" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON (map (entry: entry.linkAbsolutePath) selectedSymlinksResolved)}' \
        '${managedSymlinkManifestJson}'
    '';
  };
}
