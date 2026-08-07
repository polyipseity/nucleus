# src/modules/lib/users-registry.nix — Assemble per-user registry records from
# src/users/<username>/ domain JSON files with src/users/default/ fallback.
#
# Host-keyed fields (homeDirectory, localPath, target, enable) resolve to
# scalars for the requested hostName. customProvisionSymlinks.targets maps are
# left intact.
{
  lib,
  repoRoot,
  hostName,
}:
let
  hostKeys = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  usersRoot = repoRoot + "/src/users";

  readDirNames =
    path: builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir path));

  userNames = lib.filter (name: name != "default") (readDirNames usersRoot);

  readJsonFile =
    path:
    if builtins.pathExists path then
      removeAttrs (builtins.fromJSON (builtins.readFile path)) [ "$schema" ]
    else
      { };

  mergeRecords = default: user: lib.recursiveUpdate default user;

  isHostMap =
    value:
    builtins.isAttrs value
    && value != { }
    && builtins.all (name: builtins.elem name hostKeys) (builtins.attrNames value);

  resolveHostValue =
    value:
    if isHostMap value then
      if builtins.hasAttr hostName value then
        value.${hostName}
      else
        builtins.throw "users-registry.nix: host map missing key '${hostName}'"
    else
      value;

  resolveHostScalar =
    value: if builtins.isAttrs value && isHostMap value then resolveHostValue value else value;

  resolveCloudDriveItem =
    item:
    item
    // lib.optionalAttrs (item ? localPath) {
      localPath = resolveHostScalar item.localPath;
    }
    // lib.optionalAttrs (item ? enable) {
      enable = resolveHostScalar item.enable;
    }
    // lib.optionalAttrs (item ? readWrite) {
      readWrite = resolveHostScalar item.readWrite;
    }
    // lib.optionalAttrs (item ? fallbackTimer && builtins.isAttrs item.fallbackTimer) {
      fallbackTimer =
        item.fallbackTimer
        // lib.optionalAttrs (item.fallbackTimer ? enable) {
          enable = resolveHostScalar item.fallbackTimer.enable;
        };
    };

  resolveCloudDrives =
    cloudDrives:
    cloudDrives
    // {
      mounts = map resolveCloudDriveItem (cloudDrives.mounts or [ ]);
      replicas = map resolveCloudDriveItem (cloudDrives.replicas or [ ]);
      replicaGc = cloudDrives.replicaGc or { };
    };

  resolveDevRepos =
    devRepos:
    devRepos
    // {
      repositories = map (
        repo:
        repo
        // lib.optionalAttrs (repo ? target) {
          target = resolveHostScalar repo.target;
        }
      ) (devRepos.repositories or [ ]);
    };

  resolveProfile =
    profile:
    profile
    // lib.optionalAttrs (profile ? homeDirectory) {
      homeDirectory = resolveHostValue profile.homeDirectory;
    };

  loadDomain = username: fileName: readJsonFile (usersRoot + "/${username}/${fileName}");

  loadMergedDomain =
    username: fileName: mergeRecords (loadDomain "default" fileName) (loadDomain username fileName);

  assembleUser =
    username:
    let
      profile = resolveProfile (loadMergedDomain username "profile.json");
      cloudDrives = resolveCloudDrives (loadMergedDomain username "cloud-drives.json");
      customProvisionSymlinks =
        (loadMergedDomain username "custom-provision-symlinks.json").customProvisionSymlinks or [ ];
      devRepos = resolveDevRepos (loadMergedDomain username "dev-repos.json");
      envVars = loadMergedDomain username "env-vars.json";
      iCloudExclusions = loadMergedDomain username "icloud-exclusions.json";
      jellyfin = loadMergedDomain username "jellyfin.json";
      passwordStore = loadMergedDomain username "password-store.json";
      services = loadMergedDomain username "services.json";
      vmGuest = loadMergedDomain username "vm-guest.json";
      windows = loadMergedDomain username "windows.json";
    in
    {
      inherit (profile) isPrimary;
      homeDirectory = profile.homeDirectory or null;
      cloudDrives = {
        inherit (cloudDrives) mounts replicas replicaGc;
      };
      inherit customProvisionSymlinks;
      devRepos = {
        inherit (devRepos)
          enable
          gitHubUsername
          repositories
          submoduleDirectories
          ;
      };
      envVars = envVars;
      iCloudExclusions = {
        inherit (iCloudExclusions) excludedDirNames managedRoots;
      };
      jellyfin = {
        inherit (jellyfin) accounts libraries;
      };
      passwordStore = {
        inherit (passwordStore) path;
      };
      services = services;
      vmGuest = {
        inherit (vmGuest) passwordSecretKey usernameSecretKey;
      };
      dscConfigFiles = windows.dscConfigFiles or [ ];
      description = windows.description or "";
    };

in
lib.genAttrs userNames assembleUser
