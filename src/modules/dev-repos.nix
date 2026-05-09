# modules/dev-repos.nix — Home Manager activation hook that provisions
# development repositories in ~/dev on POSIX hosts (macOS, NixOS).
#
# Configuration: Per-user dev repository settings are defined in the centralized
# user registry (flake.nix users.<username>.devRepos). This module reads that
# configuration and provisions repositories accordingly.
#
# Behavior:
#   • symlinks are created if absent
#   • repos are cloned only if uninitialized
#   • direct submodules are individually checked and cloned if absent
#   • soft-fail on errors (log warnings, do not exit)
#   • remote URLs are verified and updated if needed
#
# Dependency:
#   • This hook runs after writeBoundary so basic file operations are available.
#   • No secrets or decryption needed; cloning happens via Git SSH (configured separately).
{ config, lib, pkgs, users, ... }:
let
  currentUserHome = config.home.homeDirectory;
  currentUsername = config.home.username;

  # Read user-specific dev repos config from the centralized user registry.
  # Falls back to disabled if not defined for this user.
  userConfig = users.${currentUsername}.devRepos or {
    enable = false;
    gitHubUsername = currentUsername;
    repositories = [];
  };
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
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Repository name (used for logging).";
          };
          target = lib.mkOption {
            type = lib.types.str;
            description = "Target path where repo/symlink should be created (e.g., ~/dev/myrepo).";
          };
          symlink = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "If set, create a symlink to this path instead of cloning.";
          };
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "If set (and symlink is null), clone from this Git URL.";
          };
        };
      });
      default = userConfig.repositories;
      description = "List of repositories to provision. Configured per-user in the user registry.";
    };
  };

  config = lib.mkIf config.nucleus.devRepos.enable {
    home.activation.devReposProvision = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export HOME="${currentUserHome}"

      devDir="$HOME/dev"
      mkdir -p "$devDir" || { echo "devReposProvision: failed to create $devDir" >&2; exit 1; }

      # Helper function: create a symlink for a repository.
      ensure_symlink() {
        local symlinkTarget="$1"
        local symlinkPath="$2"
        local repoName="$3"

        if [ ! -e "$symlinkPath" ]; then
          if ln -s "$symlinkTarget" "$symlinkPath" 2>/dev/null; then
            echo "devReposProvision: created symlink $symlinkPath -> $symlinkTarget"
          else
            echo "devReposProvision: failed to create symlink for $repoName (soft fail)" >&2
          fi
        fi
      }

      # Helper function: clone or update a repository with direct submodule support.
      ensure_repo_with_submodules() {
        local repoUrl="$1"
        local repoTarget="$2"
        local repoName="$3"

        # Check if repo is initialized.
        if [ -d "$repoTarget/.git" ]; then
          # Repo already initialized; verify/update remote.
          if [ -d "$repoTarget" ]; then
            currentRemote=$(cd "$repoTarget" 2>/dev/null && git config --get remote.origin.url 2>/dev/null || echo "")
            if [ "$currentRemote" != "$repoUrl" ]; then
              if cd "$repoTarget" 2>/dev/null && git remote set-url origin "$repoUrl" 2>/dev/null; then
                echo "devReposProvision: updated remote for $repoName to $repoUrl"
              else
                echo "devReposProvision: failed to update remote for $repoName (soft fail)" >&2
              fi
            fi
          fi

          # Ensure direct submodules are initialized.
          if [ -f "$repoTarget/.gitmodules" ]; then
            directSubmodules=$(cd "$repoTarget" 2>/dev/null && git config --file .gitmodules --name-only --get-regexp path '^[^/]+$' 2>/dev/null || echo "")
            for submodulePath in $directSubmodules; do
              submoduleTarget="$repoTarget/$submodulePath"
              if [ ! -d "$submoduleTarget/.git" ]; then
                if cd "$repoTarget" 2>/dev/null && git submodule update --init "$submodulePath" 2>/dev/null; then
                  echo "devReposProvision: initialized direct submodule $submodulePath in $repoName"
                else
                  echo "devReposProvision: failed to initialize direct submodule $submodulePath in $repoName (soft fail)" >&2
                fi
              fi
            done
          fi

          return 0
        fi

        # Repo not initialized; clone it.
        if [ -d "$repoTarget" ] && [ "$(ls -A "$repoTarget" 2>/dev/null)" != "" ]; then
          echo "devReposProvision: $repoTarget exists but is not a git repo (soft fail)" >&2
          return 0
        fi

        mkdir -p "$repoTarget" 2>/dev/null || true
        if git clone "$repoUrl" "$repoTarget" 2>/dev/null; then
          echo "devReposProvision: cloned $repoName to $repoTarget"

          # Initialize direct submodules after clone.
          if [ -f "$repoTarget/.gitmodules" ]; then
            directSubmodules=$(cd "$repoTarget" 2>/dev/null && git config --file .gitmodules --name-only --get-regexp path '^[^/]+$' 2>/dev/null || echo "")
            for submodulePath in $directSubmodules; do
              if cd "$repoTarget" 2>/dev/null && git submodule update --init "$submodulePath" 2>/dev/null; then
                echo "devReposProvision: initialized direct submodule $submodulePath in $repoName"
              else
                echo "devReposProvision: failed to initialize direct submodule $submodulePath in $repoName (soft fail)" >&2
              fi
            done
          fi

          return 0
        else
          echo "devReposProvision: failed to clone $repoName from $repoUrl (soft fail)" >&2
          return 0
        fi
      }

      # Provision configured repositories.
      ${lib.concatMapStringsSep "\n"
        (repo:
          if repo.symlink != null then
            ''ensure_symlink "${repo.symlink}" "${repo.target}" "${repo.name}"''
          else if repo.url != null then
            ''ensure_repo_with_submodules "${repo.url}" "${repo.target}" "${repo.name}"''
          else
            ''echo "devReposProvision: repository '${repo.name}' has neither symlink nor url configured (skipping)" >&2''
        )
        config.nucleus.devRepos.repositories}

      echo "devReposProvision: completed provisioning dev repositories"
    '';
  };
}
