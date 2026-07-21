# Decrypts SOPS-encrypted wallpaper blobs from assets/wallpapers/<user>/
# into ~/Pictures/wallpapers/ with a 10-minute rotating slideshow
# on macOS (desktoppr folder mode) and GNOME (wallpaper-gallery.xml).
# Activation runs after gpg-import so the keyring import has already
# happened before wallpaper decryption attempts.
# Multi-user aware: discovers user subdirectories dynamically, uses
# config.home.username for current-user wallpaper provisioning.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  wallpapersDir = ../assets/wallpapers;

  # Get all user subdirectories (each is a username).
  userDirs = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir wallpapersDir)
  );

  # Convert a wallpaper filename into a stable secret key suffix so sops-nix
  # keys remain path-safe while still being traceable to the source file.
  sanitizeSecretSuffix =
    value: lib.replaceStrings [ " " "(" ")" "." "-" ] [ "_" "" "" "_" "_" ] value;

  # For each user, collect their wallpaper blobs from their subdirectory.
  wallpaperBlobsForUser =
    userName:
    lib.attrNames (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".sops" name) (
        builtins.readDir (wallpapersDir + "/${userName}")
      )
    );

  currentUsername = config.home.username;
  currentUserHome = config.home.homeDirectory;

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
    ) (wallpaperBlobsForUser userName);

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
            path = wallpapersDir + "/${userName}/${item.blobName}";
            name = "wallpaper-${sanitizeSecretSuffix item.blobName}";
          };
        };
      }) items
    );

  # Generate wallpaper secrets for ALL user directories.
  wallpaperSecrets = lib.foldl' lib.recursiveUpdate { } (map mkWallpaperSecretsForUser userDirs);

  # Items list for the activation script - use current user's secrets.
  wallpaperItemsForCurrentUser = mkWallpaperItemsForUser currentUsername;

  # desktoppr is darwin-only; keep this reference lazy so Linux evaluation
  # does not attempt to instantiate an unsupported package.
  desktopprBinPath = if pkgs.stdenv.isDarwin then "${pkgs.desktoppr}/bin/desktoppr" else "";

  activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };
in
{
  assertions = [
    {
      assertion = builtins.pathExists wallpapersDir;
      message = "wallpapers: required wallpapers directory is missing.";
    }
    {
      assertion = builtins.elem currentUsername userDirs;
      message = "wallpapers: current user has no managed wallpaper directory.";
    }
  ];

  sops.secrets = wallpaperSecrets;

  home.activation."wallpaper-provision" = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    "${activationBundle}/provision-wallpaper.sh" \
      "${if pkgs.stdenv.isDarwin then "1" else "0"}" \
      "${currentUserHome}/Pictures/wallpapers" \
      "${desktopprBinPath}" \
      "${pkgs.coreutils}" \
      "${wallpapersDir}" \
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
