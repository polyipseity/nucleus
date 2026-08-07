# Wallpaper overlay path helpers (encrypted blobs + unencrypted images).
{
  lib,
  overlayLib,
  repoRoot,
}:
let
  wallpaperImageExtensions = [
    ".gif"
    ".jpeg"
    ".jpg"
    ".png"
    ".webp"
  ];
  isWallpaperImage =
    name:
    lib.any (ext: lib.hasSuffix ext name) wallpaperImageExtensions;
  isEncryptedBlob = name: lib.hasSuffix ".sops" name;
  listDirNames =
    dir:
    if builtins.pathExists dir then
      builtins.attrNames (builtins.readDir dir)
    else
      [ ];
  overlayArgs = {
    configName = "wallpapers";
    inherit repoRoot;
  };
in
{
  listEncryptedWallpaperBlobs =
    userName:
    let
      encryptedDir = overlayLib.selectUserConfigFirstLevelEntry (
        overlayArgs
        // {
          entryName = "encrypted";
          effectiveUsername = userName;
        }
      );
    in
    lib.filter isEncryptedBlob (listDirNames encryptedDir);

  listUnencryptedWallpaperFiles =
    userName:
    let
      wallpapersDir = overlayLib.selectUserConfigFirstLevelEntry (
        overlayArgs
        // {
          entryName = "wallpapers";
          effectiveUsername = userName;
        }
      );
    in
    lib.filter isWallpaperImage (listDirNames wallpapersDir);

  encryptedBlobPath =
    userName: blobName:
    overlayLib.selectUserConfigFile (
      overlayArgs
      // {
        relativePath = "encrypted/${blobName}";
        effectiveUsername = userName;
      }
    );

  unencryptedFilePath =
    userName: fileName:
    overlayLib.selectUserConfigFile (
      overlayArgs
      // {
        relativePath = "wallpapers/${fileName}";
        effectiveUsername = userName;
      }
    );
}
