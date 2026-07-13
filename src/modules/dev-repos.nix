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
          export PATH="${pkgs.git}/bin:$PATH"
          export GIT_SSH_COMMAND="${sshClient}"

          # Track non-fatal provisioning errors so activation output is quiet on
          # expected no-op paths but still explicit when actionable failures
          # occur.
          devReposErrors=0

          report_error() {
            devReposErrors=$((devReposErrors + 1))
            echo "devReposProvision: $1" >&2
          }

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
              report_error "repo root not set; run via apply.sh or export NUCLEUS_REPO_ROOT."
              return 1
            fi

            printf '%s\n' "$repoRoot"
          }

          # Source shared symlink protection helpers from agent-helpers.sh
          ${builtins.readFile ../scripts/agent-helpers.sh}

          # Expand glob pattern and return matching paths. If no matches, return empty.
          expand_glob_paths() {
            baseDir="$1"
            pattern="$2"

            # Use shell globbing with set -f/+f to safely expand patterns
            if [ -d "$baseDir" ]; then
              cd "$baseDir" && ls -1d $pattern 2>/dev/null
            fi
          }

          # Read direct submodule paths from the repository .gitmodules file.
          # Direct submodules are those listed in .gitmodules without nesting.
          list_direct_submodules() {
            repoTarget="$1"

            if ! submoduleConfig=$(cd "$repoTarget" && git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>&1); then
              echo "devReposProvision: failed to read .gitmodules in $repoTarget ($submoduleConfig)" >&2
              return 1
            fi

            printf '%s\n' "$submoduleConfig" | while IFS=' ' read -r _submoduleKey _submodulePath; do
              printf '%s\n' "$_submodulePath"
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
              report_error "failed to create parent directory $symlinkParent for $repoName"
              return 0
            fi

            if [ -L "$symlinkPath" ]; then
              currentTarget=$(readlink "$symlinkPath")
              if [ "$currentTarget" = "$symlinkTarget" ]; then
                # Symlink already correct; skip silently (idempotent)
                return 0
              fi

              _nucleus_unprotect_symlink "devReposProvision" "$symlinkPath"
              if ! rm "$symlinkPath"; then
                report_error "failed to replace stale symlink for $repoName"
                return 0
              fi
            elif [ -e "$symlinkPath" ]; then
              report_error "$symlinkPath exists and is not a symlink for $repoName"
              return 0
            fi

            if ln -s "$symlinkTarget" "$symlinkPath"; then
              _nucleus_protect_symlink "devReposProvision" "$symlinkPath"
              # Symlink created successfully (idempotent)
            else
              report_error "failed to create symlink for $repoName"
            fi
          }

          # Helper function: clone or update a repository (no submodule logic here).
          ensure_repo() {
            local repoUrl="$1"
            local repoTarget="$2"
            local repoName="$3"
            local parentDir
            local currentRemote
            local remoteErr
            local cloneErr

            parentDir=$(dirname "$repoTarget")
            if ! mkdir -p "$parentDir"; then
              report_error "failed to create parent directory $parentDir for $repoName"
              return 0
            fi

            # Check if repo is initialized.
            if [ -d "$repoTarget/.git" ]; then
              # Repo already initialized; verify/update remote.
              if [ -d "$repoTarget" ]; then
                if ! currentRemote=$(cd "$repoTarget" && git config --get remote.origin.url 2>&1); then
                  report_error "failed to read remote for $repoName ($currentRemote)"
                  currentRemote=""
                fi

                if [ "$currentRemote" != "$repoUrl" ]; then
                  if remoteErr=$(cd "$repoTarget" && git remote set-url origin "$repoUrl" 2>&1); then
                    # Remote updated successfully (idempotent)
                    :
                  else
                    report_error "failed to update remote for $repoName ($remoteErr)"
                  fi
                fi
              fi

              return 0
            fi

            # Repo not initialized; clone it.
            if [ -e "$repoTarget" ] && [ ! -d "$repoTarget" ]; then
              report_error "$repoTarget exists and is not a directory"
              return 0
            fi

            if [ -d "$repoTarget" ] && [ "$(ls -A "$repoTarget" 2>/dev/null)" != "" ]; then
              report_error "$repoTarget exists but is not a git repo"
              return 0
            fi

            if cloneErr=$(git clone "$repoUrl" "$repoTarget" 2>&1); then
              # Repository cloned successfully (idempotent)
              return 0
            else
              report_error "failed to clone $repoName from $repoUrl ($cloneErr)"
              return 0
            fi
          }

          # Helper function: clone direct submodules from a directory path.
          # Arguments: directoryPath recursive(0|1) directoryLabel
          resolve_submodule_branch() {
            local repoPath="$1"
            local submodulePath="$2"
            local submoduleConfigKey
            local submoduleName
            local branchName
            local originHeadRef

            # Map submodule path -> submodule.<name>.path key in .gitmodules.
            submoduleConfigKey="$(
              cd "$repoPath" && git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | while IFS=' ' read -r _key _path; do
                if [ "$_path" = "$submodulePath" ]; then
                  printf '%s\n' "$_key"
                  break
                fi
              done
            )"
            [ -n "$submoduleConfigKey" ] || return 1

            submoduleName="''${submoduleConfigKey#submodule.}"
            submoduleName="''${submoduleName%.path}"

            # submodule.<name>.branch is optional in .gitmodules; absence means
            # "follow remote HEAD".
            # WHY: git config --get exits 1 when the key does not exist.
            branchName="$(cd "$repoPath" && git config --file .gitmodules --get "submodule.$submoduleName.branch" || true)"
            if [ "$branchName" = "." ] || [ -z "$branchName" ]; then
              # WHY: remote HEAD may not exist for detached submodules; git symbolic-ref exits 1 on detached HEAD (fallback below extracts branch name).
              originHeadRef="$(cd "$repoPath/$submodulePath" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
              branchName="''${originHeadRef#origin/}"
            fi

            [ -n "$branchName" ] || return 1
            printf '%s\n' "$branchName"
          }

          ensure_fresh_submodule_on_branch() {
            local repoPath="$1"
            local submodulePath="$2"
            local dirLabel="$3"
            local submoduleTarget
            local currentBranch
            local branchName
            local branchErr

            submoduleTarget="$repoPath/$submodulePath"
            [ -e "$submoduleTarget/.git" ] || return 0

            if currentBranch=$(cd "$submoduleTarget" && git symbolic-ref --quiet --short HEAD 2>&1); then
              echo "devReposProvision: submodule $submodulePath already on branch '$currentBranch' after initialization in $dirLabel"
              return 0
            fi

            if ! branchName=$(resolve_submodule_branch "$repoPath" "$submodulePath"); then
              report_error "could not resolve branch for freshly initialized submodule $submodulePath in $dirLabel (leaving detached)"
              return 0
            fi

            if branchErr=$(cd "$submoduleTarget" && git checkout "$branchName" 2>&1); then
              echo "devReposProvision: checked out freshly initialized submodule $submodulePath on branch '$branchName' in $dirLabel"
              return 0
            fi

            if branchErr=$(cd "$submoduleTarget" && git checkout -b "$branchName" --track "origin/$branchName" 2>&1); then
              echo "devReposProvision: created+checked out branch '$branchName' for freshly initialized submodule $submodulePath in $dirLabel"
            else
              report_error "failed to switch freshly initialized submodule $submodulePath to branch '$branchName' in $dirLabel ($branchErr)"
            fi
          }

          clone_directory_submodules() {
            local dirPath="$1"
            local recursive="$2"
            local dirLabel="$3"
            local directSubmodules
            local submodulePath
            local submoduleTarget
            local submoduleErr

            # Directory must exist and have a .gitmodules file
            if [ ! -f "$dirPath/.gitmodules" ]; then
              # No submodules configured in this directory; benign no-op.
              return 0
            fi

            if ! directSubmodules=$(list_direct_submodules "$dirPath"); then
              report_error "failed to list submodules in $dirLabel"
              return 0
            fi

            # Initialize each direct submodule
            for submodulePath in $directSubmodules; do
              submoduleTarget="$dirPath/$submodulePath"

              if [ -e "$submoduleTarget/.git" ]; then
                # Already initialized; idempotent no-op.
                continue
              fi

              if [ "$recursive" = "1" ]; then
                if submoduleErr=$(cd "$dirPath" && git submodule update --init --recursive "$submodulePath" 2>&1); then
                  echo "devReposProvision: initialized submodule $submodulePath (recursive) in $dirLabel"
                  ensure_fresh_submodule_on_branch "$dirPath" "$submodulePath" "$dirLabel"
                else
                  report_error "failed to initialize submodule $submodulePath (recursive) in $dirLabel ($submoduleErr)"
                fi
              else
                if submoduleErr=$(cd "$dirPath" && git submodule update --init "$submodulePath" 2>&1); then
                  echo "devReposProvision: initialized submodule $submodulePath in $dirLabel"
                  ensure_fresh_submodule_on_branch "$dirPath" "$submodulePath" "$dirLabel"
                else
                  report_error "failed to initialize submodule $submodulePath in $dirLabel ($submoduleErr)"
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
