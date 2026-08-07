# Decrypts SOPS-encrypted wallpaper blobs from src/users/<user>/wallpapers/
# (first-level overlay merge with src/users/default/wallpapers/) into
# ~/Pictures/wallpapers/ with a 10-minute rotating slideshow on macOS
# (desktoppr folder mode) and GNOME (wallpaper-gallery.xml).
# Activation runs after gpg-import so the keyring import has already
# happened before wallpaper decryption attempts.
# Multi-user aware: discovers managed users from users-registry, uses
# config.home.username for current-user wallpaper provisioning.
{
  config,
  lib,
  pkgs,
  users ? { },
  ...
}:
let
  repoRoot = ../../.;
  overlayLib = import ./lib/users-overlay.nix;

  managedUserNames = builtins.attrNames users;

  # Convert a wallpaper filename into a stable secret key suffix so sops-nix
  # keys remain path-safe while still being traceable to the source file.
  sanitizeSecretSuffix =
    value: lib.replaceStrings [ " " "(" ")" "." "-" ] [ "_" "" "" "_" "_" ] value;

  listWallpaperBlobsForUser =
    userName:
    let
      entries = overlayLib.listUserConfigFirstLevelEntries {
        configName = "wallpapers";
        effectiveUsername = userName;
        repoRoot = repoRoot;
      };
    in
    lib.filter (name: lib.hasSuffix ".sops" name) entries;

  wallpaperBlobPath =
    userName: blobName:
    overlayLib.selectUserConfigFirstLevelEntry {
      configName = "wallpapers";
      entryName = blobName;
      effectiveUsername = userName;
      repoRoot = repoRoot;
    };

  # Build normalized wallpaper item metadata for a user once so secret
  # generation and activation wiring share the same source of truth.
  mkWallpaperItemsForUser =
    userName:
    map (
      blobName:
      let
        wallpaperName = lib.removeSuffix ".sops" blobName;
      in
      {
        inherit blobName wallpaperName;
        secretName = "wallpaper_${sanitizeSecretSuffix wallpaperName}_${userName}";
      }
    ) (listWallpaperBlobsForUser userName);

  usersWithWallpapers =
    lib.filter (userName: (listWallpaperBlobsForUser userName) != [ ]) managedUserNames;

  # Generate wallpaper secrets for a given user.
  mkWallpaperSecretsForUser =
    userName:
    let
      items = mkWallpaperItemsForUser userName;
    in
    lib.listToAttrs (
      map (item: {
        name = item.secretName;
        value = {
          format = "binary";
          mode = "0400";
          sopsFile = builtins.path {
            path = wallpaperBlobPath userName item.blobName;
            name = "wallpaper-${sanitizeSecretSuffix item.blobName}";
          };
        };
      }) items
    );

  # Generate wallpaper secrets for all managed users with overlay wallpapers.
  wallpaperSecrets = lib.foldl' lib.recursiveUpdate { } (map mkWallpaperSecretsForUser usersWithWallpapers);

  currentUsername = config.home.username;
  currentUserHome = config.home.homeDirectory;

  # Items list for the activation script - use current user's merged overlay.
  wallpaperItemsForCurrentUser = mkWallpaperItemsForUser currentUsername;

  # desktoppr is darwin-only; keep this reference lazy so Linux evaluation
  # does not attempt to instantiate an unsupported package.
  desktopprBinPath = if pkgs.stdenv.isDarwin then "${pkgs.desktoppr}/bin/desktoppr" else "";

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  assertions = [
    {
      assertion = (listWallpaperBlobsForUser currentUsername) != [ ];
      message = "wallpapers: current user has no managed wallpaper blobs in the user overlay.";
    }
  ];

  sops.secrets = wallpaperSecrets;

  home.activation.provision-wallpapers = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    "${activationBundle}/src/scripts/provision-wallpaper.sh" \
      "${if pkgs.stdenv.isDarwin then "1" else "0"}" \
      "${currentUserHome}/Pictures/wallpapers" \
      "${desktopprBinPath}" \
      "${pkgs.coreutils}" \
      "${repoRoot}" \
      "${currentUsername}" \
      "${config.sops.defaultSymlinkPath}" \
      '${
        builtins.toJSON (
          map (item: {
            secretName = item.secretName;
            wallpaperName = item.wallpaperName;
          }) wallpaperItemsForCurrentUser
        )
      }' \
      "${pkgs.jq}/bin/jq"
  '';
}
