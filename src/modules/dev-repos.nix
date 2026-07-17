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
    home.activation.devReposProvision =
      lib.hm.dag.entryAfter
        [
          "gitIdentityFromSops"
          "gpgImport"
          "sshKeyAdopt"
          "verifySecretDecryption"
          "waitForSopsSecrets"
          "writeBoundary"
        ]
        ''
          set -eu

          export HOME="${currentUserHome}"
          export PATH="$PATH:${pkgs.git}/bin"
          export GIT_SSH_COMMAND="${sshClient}"

          # Resolve the live checkout root from $NUCLEUS_REPO_ROOT (set by apply.sh
          # before the rebuild and forwarded through sudo), with an eval-time
          # fallback for home-manager activation (which runs as the user and
          # does not inherit the sudo-level env var). Repo-root symlinks must
          # target the mutable working tree rather than the Nix store copy of
          # flake inputs, or ~/dev/nucleus drifts away from the user's actual
          # checkout after every rebuild.
          repoRoot="${repoRoot}"
          if [ -z "$repoRoot" ] || [ ! -d "$repoRoot" ]; then
            if [ -n "''${NUCLEUS_REPO_ROOT:-}" ]; then
              repoRoot="$NUCLEUS_REPO_ROOT"
            fi
          fi

          devDir="$HOME/dev"
          mkdir -p "$devDir" || { echo "devReposProvision: failed to create $devDir" >&2; exit 1; }

          # Source shared symlink protection helpers from agent-helpers.sh
          ${builtins.readFile ../scripts/agent-helpers.sh}

          # Source dev-repos helper functions
          ${builtins.readFile ../scripts/dev-repos-provision-lib.sh}"
                fi
              fi
            done
          }

          # Step 1: Provision configured repositories
          ${lib.concatMapStringsSep "\n" (
            repo:
            if repo.symlinkFromRepoRoot then
              ''
                repoTargetPath="$(resolve_repo_path "${repo.target}")"
                if repoSymlinkTarget="$(resolve_repo_root_target)"; then
                  ensure_symlink "$repoSymlinkTarget" "$repoTargetPath" "${repo.name}"
                else
                  report_error "repo-root symlink target unavailable for ${repo.name}"
                fi
              ''
            else if repo.symlink != null then
              ''ensure_symlink "$(resolve_repo_path "${repo.symlink}")" "$(resolve_repo_path "${repo.target}")" "${repo.name}"''
            else if repo.url != null then
              ''ensure_repo "${repo.url}" "$(resolve_repo_path "${repo.target}")" "${repo.name}"''
            else
              ''report_error "repository '${repo.name}' has neither symlink nor url configured"''
          ) config.nucleus.devRepos.repositories}

          # Step 2: Clone submodules from specified directories (sequential processing)
          ${lib.concatMapStringsSep "\n" (
            submoduleDir:
            let
              recursive = if submoduleDir.recursive then "1" else "0";
            in
            ''
              # Expand glob patterns in submodule directory paths
              resolvedPath="$(resolve_repo_path "${submoduleDir.path}")"

              # Check if path contains glob characters
              case "$resolvedPath" in
                *\*|*\?|*\[*)
                  # Glob pattern detected; expand it
                  baseDir=$(dirname "$resolvedPath")
                  pattern=$(basename "$resolvedPath")
                  if [ -d "$baseDir" ]; then
                    expandedPaths=$(expand_glob_paths "$baseDir" "$pattern")
                    if [ -z "$expandedPaths" ]; then
                      # No matches for configured glob; benign no-op.
                      :
                    else
                      while IFS= read -r matchedPath; do
                        clone_directory_submodules "$matchedPath" "${recursive}" "''${matchedPath#$HOME/}"
                      done <<< "$expandedPaths"
                    fi
                  else
                    report_error "base directory $baseDir does not exist for glob pattern '${submoduleDir.path}'"
                  fi
                  ;;
                *)
                  # No glob; process literal path
                  if [ -d "$resolvedPath" ]; then
                    clone_directory_submodules "$resolvedPath" "${recursive}" "${submoduleDir.path}"
                  else
                    report_error "directory '${submoduleDir.path}' does not exist"
                  fi
                  ;;
              esac
            ''
          ) config.nucleus.devRepos.submoduleDirectories}

          echo "devReposProvision: completed provisioning dev repositories and submodules"
          if [ "$devReposErrors" -gt 0 ]; then
            echo "devReposProvision: completed with $devReposErrors non-fatal error(s); see messages above." >&2
          fi
        '';
  };
}
