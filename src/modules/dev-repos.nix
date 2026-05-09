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
  # macOS ssh_config commonly uses Apple-only directives such as UseKeychain.
  # Git-over-SSH must therefore use /usr/bin/ssh on Darwin; the Nix OpenSSH
  # client rejects those directives and breaks clones during activation.
  sshClient = if pkgs.stdenv.isDarwin then "/usr/bin/ssh" else "${pkgs.openssh}/bin/ssh";

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
      });
      default = userConfig.repositories;
      description = "List of repositories to provision. Configured per-user in the user registry.";
    };
  };

  config = lib.mkIf config.nucleus.devRepos.enable {
    home.activation.devReposProvision = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu

      export HOME="${currentUserHome}"
      export PATH="${pkgs.git}/bin:$PATH"
      export GIT_SSH_COMMAND="${sshClient}"

      # Resolve the live checkout root written by apply.sh before the rebuild.
      # Repo-root symlinks must target the mutable working tree rather than the
      # Nix store copy of flake inputs, or ~/dev/nucleus drifts away from the
      # user's actual checkout after every rebuild.
      repoRootFile="$HOME/.config/nucleus/repo-root"
      repoRoot=""
      gitBin="${pkgs.git}/bin/git"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        repoRoot="$NUCLEUS_REPO"
      elif [ -f "$repoRootFile" ]; then
        repoRoot="$(cat "$repoRootFile")"
      fi

      devDir="$HOME/dev"
      mkdir -p "$devDir" || { echo "devReposProvision: failed to create $devDir" >&2; exit 1; }

      # Convert declarative repo paths into real filesystem paths for the
      # managed user. Relative paths live under $HOME; ~/... expands to the
      # same place explicitly because quoted shell arguments suppress tilde
      # expansion.
      resolve_repo_path() {
        pathInput="$1"

        case "$pathInput" in
          "~")
            printf '%s\n' "$HOME"
            ;;
          ~/*)
            printf '%s/%s\n' "$HOME" "''${pathInput#~/}"
            ;;
          /*)
            printf '%s\n' "$pathInput"
            ;;
          *)
            printf '%s/%s\n' "$HOME" "$pathInput"
            ;;
        esac
      }

      # Repo-root-backed symlinks are only valid when apply.sh has recorded the
      # live checkout path. Failing fast here avoids quietly linking dev repos
      # to an empty string or a stale store path.
      resolve_repo_root_target() {
        if [ -z "$repoRoot" ]; then
          echo "devReposProvision: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
          return 1
        fi

        printf '%s\n' "$repoRoot"
      }

      # Read only top-level submodule paths from .gitmodules. The earlier
      # name-only query returned config keys rather than paths, so nested repo
      # initialization quietly targeted nonsense paths.
      list_direct_submodules() {
        repoTarget="$1"

        if ! submoduleConfig=$(cd "$repoTarget" && "$gitBin" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>&1); then
          echo "devReposProvision: failed to read .gitmodules in $repoTarget ($submoduleConfig)" >&2
          return 1
        fi

        printf '%s\n' "$submoduleConfig" | while IFS=' ' read -r _submoduleKey _submodulePath; do
          case "$_submodulePath" in
            */*)
              ;;
            *)
              printf '%s\n' "$_submodulePath"
              ;;
          esac
        done
      }

      # Helper function: create a symlink for a repository.
      ensure_symlink() {
        local symlinkTarget="$1"
        local symlinkPath="$2"
        local repoName="$3"
        local currentTarget
        local symlinkParent

        symlinkParent=$(dirname "$symlinkPath")
        if ! mkdir -p "$symlinkParent"; then
          echo "devReposProvision: failed to create parent directory $symlinkParent for $repoName" >&2
          return 0
        fi

        if [ -L "$symlinkPath" ]; then
          currentTarget=$(readlink "$symlinkPath")
          if [ "$currentTarget" = "$symlinkTarget" ]; then
            echo "devReposProvision: symlink for $repoName already points to $symlinkTarget"
            return 0
          fi

          if ! rm "$symlinkPath"; then
            echo "devReposProvision: failed to replace stale symlink for $repoName" >&2
            return 0
          fi
        elif [ -e "$symlinkPath" ]; then
          echo "devReposProvision: $symlinkPath exists and is not a symlink for $repoName (soft fail)" >&2
          return 0
        fi

        if ln -s "$symlinkTarget" "$symlinkPath"; then
          echo "devReposProvision: linked $symlinkPath -> $symlinkTarget"
        else
          echo "devReposProvision: failed to create symlink for $repoName (soft fail)" >&2
        fi
      }

      # Helper function: clone or update a repository with direct submodule support.
      ensure_repo_with_submodules() {
        local repoUrl="$1"
        local repoTarget="$2"
        local repoName="$3"
        local parentDir
        local currentRemote
        local remoteErr
        local directSubmodules
        local submodulePath
        local submoduleTarget
        local submoduleErr
        local cloneErr

        parentDir=$(dirname "$repoTarget")
        if ! mkdir -p "$parentDir"; then
          echo "devReposProvision: failed to create parent directory $parentDir for $repoName" >&2
          return 0
        fi

        # Check if repo is initialized.
        if [ -d "$repoTarget/.git" ]; then
          # Repo already initialized; verify/update remote.
          if [ -d "$repoTarget" ]; then
            if ! currentRemote=$(cd "$repoTarget" && "$gitBin" config --get remote.origin.url 2>&1); then
              echo "devReposProvision: failed to read remote for $repoName ($currentRemote)" >&2
              currentRemote=""
            fi

            if [ "$currentRemote" != "$repoUrl" ]; then
              if remoteErr=$(cd "$repoTarget" && "$gitBin" remote set-url origin "$repoUrl" 2>&1); then
                echo "devReposProvision: updated remote for $repoName to $repoUrl"
              else
                echo "devReposProvision: failed to update remote for $repoName ($remoteErr)" >&2
              fi
            fi
          fi

          # Ensure direct submodules are initialized.
          if [ -f "$repoTarget/.gitmodules" ]; then
            if directSubmodules=$(list_direct_submodules "$repoTarget"); then
              for submodulePath in $directSubmodules; do
                submoduleTarget="$repoTarget/$submodulePath"
                if [ ! -d "$submoduleTarget/.git" ]; then
                  if submoduleErr=$(cd "$repoTarget" && "$gitBin" submodule update --init "$submodulePath" 2>&1); then
                    echo "devReposProvision: initialized direct submodule $submodulePath in $repoName"
                  else
                    echo "devReposProvision: failed to initialize direct submodule $submodulePath in $repoName ($submoduleErr)" >&2
                  fi
                fi
              done
            else
              echo "devReposProvision: skipping direct submodule initialization in $repoName after .gitmodules read failure" >&2
            fi
          fi

          return 0
        fi

        # Repo not initialized; clone it.
        if [ -e "$repoTarget" ] && [ ! -d "$repoTarget" ]; then
          echo "devReposProvision: $repoTarget exists and is not a directory (soft fail)" >&2
          return 0
        fi

        if [ -d "$repoTarget" ] && [ "$(ls -A "$repoTarget" 2>/dev/null)" != "" ]; then
          echo "devReposProvision: $repoTarget exists but is not a git repo (soft fail)" >&2
          return 0
        fi

        if cloneErr=$("$gitBin" clone "$repoUrl" "$repoTarget" 2>&1); then
          echo "devReposProvision: cloned $repoName to $repoTarget"

          # Initialize direct submodules after clone.
          if [ -f "$repoTarget/.gitmodules" ]; then
            if directSubmodules=$(list_direct_submodules "$repoTarget"); then
              for submodulePath in $directSubmodules; do
                submoduleTarget="$repoTarget/$submodulePath"
                if [ ! -d "$submoduleTarget/.git" ]; then
                  if submoduleErr=$(cd "$repoTarget" && "$gitBin" submodule update --init "$submodulePath" 2>&1); then
                    echo "devReposProvision: initialized direct submodule $submodulePath in $repoName"
                  else
                    echo "devReposProvision: failed to initialize direct submodule $submodulePath in $repoName ($submoduleErr)" >&2
                  fi
                fi
              done
            else
              echo "devReposProvision: skipping direct submodule initialization in $repoName after .gitmodules read failure" >&2
            fi
          fi

          return 0
        else
          echo "devReposProvision: failed to clone $repoName from $repoUrl ($cloneErr)" >&2
          return 0
        fi
      }

      # Provision configured repositories. Targets are resolved relative to the
      # managed home directory so declarative entries can stay cross-host and
      # avoid brittle literal /Users/... paths in flake data.
      ${lib.concatMapStringsSep "\n"
        (repo:
          if repo.symlinkFromRepoRoot then
            ''
              repoTargetPath="$(resolve_repo_path "${repo.target}")"
              if repoSymlinkTarget="$(resolve_repo_root_target)"; then
                ensure_symlink "$repoSymlinkTarget" "$repoTargetPath" "${repo.name}"
              else
                echo "devReposProvision: repo-root symlink target unavailable for ${repo.name} (skipping)" >&2
              fi
            ''
          else if repo.symlink != null then
            ''ensure_symlink "$(resolve_repo_path "${repo.symlink}")" "$(resolve_repo_path "${repo.target}")" "${repo.name}"''
          else if repo.url != null then
            ''ensure_repo_with_submodules "${repo.url}" "$(resolve_repo_path "${repo.target}")" "${repo.name}"''
          else
            ''echo "devReposProvision: repository '${repo.name}' has neither symlink nor url configured (skipping)" >&2''
        )
        config.nucleus.devRepos.repositories}

      echo "devReposProvision: completed provisioning dev repositories"
    '';
  };
}
