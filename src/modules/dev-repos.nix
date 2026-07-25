# Provisions dev repos in ~/dev from per-user config in users.json.
args@{
  config,
  lib,
  pkgs,
  ...
}:
let
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  users = args.users or { };
  currentUserHome = config.home.homeDirectory;
  currentUsername = config.home.username;
  # macOS ssh_config commonly uses Apple-only directives such as UseKeychain.
  # Git-over-SSH must therefore use /usr/bin/ssh on Darwin; the Nix OpenSSH
  # client rejects those directives and breaks clones during activation.
  sshClient = if pkgs.stdenv.isDarwin then "/usr/bin/ssh" else "${pkgs.openssh}/bin/ssh";

  # Read user-specific dev repos config from the centralized user registry.
  # Falls back to disabled if not defined for this user.
  userConfig =
    users.${currentUsername}.devRepos or {
      enable = false;
      gitHubUsername = currentUsername;
      repositories = [ ];
      submoduleDirectories = [ ];
    };

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  options.nucleus.devRepos = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = userConfig.enable;
      description = "Whether to provision dev repositories in ~/dev. Configured per-user in the user registry.";
    };

    gitHubUsername = lib.mkOption {
      type = lib.types.str;
      default = userConfig.gitHubUsername;
      description = "GitHub username for repository cloning. Configured per-user in the user registry.";
    };

    repositories = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Repository name (used for logging).";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "Target path where repo/symlink should be created. Relative paths are resolved under the managed user's home directory; absolute paths are used as-is.";
            };
            symlink = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "If set, create a symlink to this path instead of cloning. Relative paths are resolved under the managed user's home directory; absolute paths are used as-is.";
            };
            symlinkFromRepoRoot = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "When true, use the live repository checkout root recorded by apply.sh as the symlink target. This keeps dev symlinks pointed at the working tree instead of a Nix store snapshot.";
            };
            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "If set (and symlink is null), clone from this Git URL.";
            };
          };
        }
      );
      default = userConfig.repositories;
      description = "List of repositories to provision (clone/symlink). Configured per-user in the user registry.";
    };

    submoduleDirectories = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Directory path where direct submodules should be cloned. Supports globbing (e.g., 'myrepo/subdir/*'). Relative paths are resolved under the managed user's home directory.";
            };
            recursive = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to recursively clone nested submodules (--recursive flag). Presence of this directory implies submodules are enabled.";
            };
          };
        }
      );
      default = userConfig.submoduleDirectories;
      description = "List of folder directories where submodules should be cloned. Processed sequentially to support dependencies between clones. Configured per-user in the user registry.";
    };
  };

  config = lib.mkIf config.nucleus.devRepos.enable {
    # dev repos clone over Git SSH and may rely on the managed SSH key, Git
    # identity include, and decryption health checks from secrets.nix. Keep
    # this activation ordered after the secrets pipeline so every managed user
    # sees the same post-secrets provisioning order on both macOS and NixOS.
    home.activation.provision-dev-repos =
      lib.hm.dag.entryAfter
        [
          "git-identity"
          "gpg-import"
          "ssh-key-adopt"
          "verify-secret-decryption"
          "wait-for-sops-secrets"
          "writeBoundary"
        ]
        ''
          "${activationBundle}/src/scripts/configs/provision-dev-repos.sh" \
            "${currentUserHome}" \
            "${pkgs.git}/bin" \
            "${sshClient}" \
            "${repoRoot}" \
            "${pkgs.jq}/bin/jq" \
            '${builtins.toJSON config.nucleus.devRepos}'
        '';
  };
}
