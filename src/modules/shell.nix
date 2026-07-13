# Interactive shell configuration shared across all managed hosts.
#
# History exclusion features enabled here:
#   - HIST_IGNORE_SPACE: exclude commands starting with a space
#   - HIST_IGNORE_DUPS:  exclude consecutive duplicate commands
#
# When adding a new shell (bash, fish, nushell, etc.), enable the equivalent:
#   - bash:   HISTCONTROL=ignorespace:ignoredups
#   - fish:   fish_history ignore-space (or custom function)
#   - nu:     $env.config.shell_integration.history.exclude_patterns or similar
#   - cmd.exe: no equivalent — cannot be implemented
{
  config,
  lib,
  pkgs,
  nucleusApps,
  users ? null,
  ...
}:
let
  # Dedicated alias/env fragments keep list-like attrsets isolated so sort order
  # can be audited without scanning unrelated shell options.
  shellAliases = import ./shell/aliases.nix { };
  sessionVariables = import ./shell/env.nix { inherit pkgs; };

  # Single source of truth for AI agent session detection.  Shared with
  # pwsh.nix and Sync-ShellProfile.ps1 (Windows).
  agentEnv = import ./agent-env-vars.nix;

  # Keep a user-scoped baseline toolchain available even in repositories that do
  # not ship direnv or Nix metadata. This preserves the "no direct system tool
  # invocation" policy while still giving unmanaged projects a predictable bun /
  # uv / prek bundle.  Rust toolchain management is via rustup on all platforms;
  # cargo/rustc are not included here so users go through rustup or a devShell.
  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.prek
      pkgs.uv
    ];
  };

  # Publish the fallback toolchain path as a session variable so every managed
  # shell can reach the same user-scoped binaries without duplicating the store
  # path string in multiple helper functions.
  mergedSessionVariables =
    sessionVariables
    // {
      NUCLEUS_DEFAULT_DEV_BIN = "${defaultDevTools}/bin";
      NUCLEUS_DEFAULT_DEV_ENV = "1";
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      # WHY: rustc and cargo invoke `/usr/bin/xcrun --sdk macosx --show-sdk-path`
      # directly during native-code builds (unrelated to $CC resolution).  Without
      # Xcode CLT installed, xcrun pops the installation dialog.  DEVELOPER_DIR
      # pointing at the Nix apple-sdk lets xcrun discover the SDK from the Nix store
      # — no CLT needed.  Verified: `env -i DEVELOPER_DIR=<nix-apple-sdk>
      # /usr/bin/xcrun --sdk macosx --show-sdk-path` succeeds without dialog.
      # macOS-only: apple-sdk is not available on NixOS/Windows.
      DEVELOPER_DIR = "${pkgs.apple-sdk}";

      # WHY: same rationale as DEVELOPER_DIR — xcrun needs the full SDK path.
      # Without this, xcrun --show-sdk-path fails even when DEVELOPER_DIR is set
      # correctly, because xcrun looks up SDKROOT internally based on DEVELOPER_DIR
      # but having it explicit avoids a second xcrun invocation.
      SDKROOT = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";

      # WHY: rustup-managed cargo on macOS needs libiconv in LIBRARY_PATH when
      # building crates with C dependencies (for example openssl-sys, libgit2-sys).
      # Without this, the system linker fails with "ld: library not found for -liconv".
      # In devShells (use flake), buildInputs = [libiconv] handles this via NIX_LDFLAGS.
      # For interactive sessions outside a devShell — including rustup run stable cargo
      # and cargo in a directory that has only .envrc (even empty) with a rust-toolchain.toml
      # — this persistent variable ensures the linker finds Nix's libiconv.
      LIBRARY_PATH = "${pkgs.libiconv}/lib";
    };

  # Keep iCloud exclusion names and managed root paths in one declarative source
  # (users.json) so activation-time recursive marking and interactive shell hooks
  # converge on the same directory-name and managed-root policy.
  # Only Mobile Documents subpaths are valid managed roots here: the ignore xattr
  # is a native iCloud File Provider mechanism and must not be applied to legacy
  # convenience aliases like ~/Downloads/iCloud or ~/clouds/iCloud.
  _iCloudCfg =
    let
      allUsers = builtins.fromJSON (builtins.readFile ./users.json);
      effectiveUsers = if users != null then users else allUsers;
      currentUser = config.home.username;
      perUser =
        if
          builtins.hasAttr currentUser effectiveUsers
          && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
        then
          effectiveUsers.${currentUser}.iCloudExclusions
        else
          { };
      normalizeRoot = root: lib.removeSuffix "/." root;
      sanitizedManagedRoots =
        let
          candidateRoots = map normalizeRoot (perUser.managedRoots or [ ]);
          mobileDocumentsRoots = builtins.filter (
            root: root != "Library/Mobile Documents" && lib.hasPrefix "Library/Mobile Documents/" root
          ) candidateRoots;
        in
        if mobileDocumentsRoots != [ ] then
          mobileDocumentsRoots
        else
          [ "Library/Mobile Documents/com~apple~CloudDocs" ];
    in
    {
      excludedDirNames = perUser.excludedDirNames or [ ];
      managedRoots = sanitizedManagedRoots;
    };

  iCloudExcludedDirNames = _iCloudCfg.excludedDirNames;
  iCloudManagedRoots = _iCloudCfg.managedRoots;

in
{
  home.packages = builtins.attrValues nucleusApps;

  # direnv: automatically loads/unloads per-directory environments.
  # nix-direnv: caches nix-shell/flake devShells so re-entering a directory
  # does not trigger a full Nix evaluation each time.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # zoxide: a faster 'cd' that learns frequently used directories.
  # Integrates with zsh so 'z <query>' works in interactive sessions.
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    autosuggestion.enable = true; # inline history suggestions
    enable = true;
    enableCompletion = true; # tab completion via compinit
    shellAliases = shellAliases;
    syntaxHighlighting.enable = true; # command colouring (valid = green, etc.)

    # -----------------------------------------------------------------------
    # initContent: pay-respects shell integration + system-wide Python ban
    # -----------------------------------------------------------------------
    # pay-respects is initialised here rather than via a shell alias because
    # `eval "$(pay-respects zsh --alias)"` creates a zsh FUNCTION named `f`
    # that captures shell history and auto-executes the corrected command via
    # eval.  A plain alias (aliases.nix) would shadow the function — aliases
    # expand before functions in zsh — leaving `f` as a bare binary invocation
    # that neither executes the fix nor records it in history.
    # The build-tool ban wrappers follow; they must remain as functions (not aliases)
    # so they can emit multi-line guidance via heredoc and pass through when in a
    # devShell (DIRENV_DIR set) or via the managed default toolchain.
    initContent = ''
            # ---------------------------------------------------------------
            # History: exclude commands starting with a space and duplicates
            # ---------------------------------------------------------------
            setopt HIST_IGNORE_SPACE
            setopt HIST_IGNORE_DUPS

            # ---------------------------------------------------------------
            # Writable user-local completion directory
            # ---------------------------------------------------------------
            # Home Manager's fpath points to Nix store paths (read-only).
            # Tools like `gh completion -s zsh > file` cannot write there, so
            # provide a writable XDG-compliant fallback.
            typeset -g ZSH_COMPLETION_DIR="$HOME/.local/share/zsh/completions"
            mkdir -p "$ZSH_COMPLETION_DIR"
            fpath+=("$ZSH_COMPLETION_DIR")

            # Refresh completion cache so the new fpath entry is recognised.
            # -C: skip full rebuild if dump is current (fast path).
            # -i: silently ignore "insecure" user-writable dirs (expected).
            compinit -C -i -d "$HOME/.zcompdump"

            # ---------------------------------------------------------------
            # AI agent session detection
            # ---------------------------------------------------------------
            # Environment variable names sourced from src/modules/agent-env-vars.nix.
            __nucleus_is_agent_session() {
              ${lib.concatStringsSep "\n" (
                map (v: "              [[ -n \"\${${v}:-}\" ]] && return 0") agentEnv.agentEnvVarNames
              )}
              [[ -d ${agentEnv.devinPosixPath} ]] && return 0
              return 1
            }

            # ---------------------------------------------------------------
            # Interactive-feature suppression in AI agent sessions
            # ---------------------------------------------------------------
            # When an AI agent is detected, disable multi-line editing features
            # that clutter agent output and serve no purpose in non-human sessions.
            if __nucleus_is_agent_session; then
              unsetopt ZLE
              PS2=""
              PS1="%% "
            fi

            # ---------------------------------------------------------------
            # pay-respects shell hook
            # ---------------------------------------------------------------
            # Only initialise in interactive shells. In non-interactive or AI
            # agent sessions, pay-respects would block on its interactive prompt
            # with no user to respond.
            #
            # pay-respects is initialised here rather than via a shell alias because
            # `eval "$(pay-respects zsh --alias)"` creates a zsh FUNCTION named `f`
            # that captures shell history and auto-executes the corrected command via
            # eval.  A plain alias (aliases.nix) would shadow the function -- aliases
            # expand before functions in zsh -- leaving `f` as a bare binary invocation
            # that neither executes the fix nor records it in history.
            if [[ -o interactive ]] && ! __nucleus_is_agent_session; then
              eval "$(pay-respects zsh --alias)"
            fi

            # ---------------------------------------------------------------
            # Starship prompt
            # ---------------------------------------------------------------
            if command -v starship >/dev/null 2>&1; then
              eval "$(starship init zsh)"
            fi

            # home.sessionVariables does not reliably populate plain interactive
            # `zsh -i` sessions in every launch path, so export the fallback tool
            # coordinates here as well.  This keeps repositories without .envrc
            # usable even when the shell did not start as a login shell.
            export NUCLEUS_DEFAULT_DEV_BIN="${defaultDevTools}/bin"
            export NUCLEUS_DEFAULT_DEV_ENV="1"

            # (User-scope package manager bin dirs are declared via home.sessionPath
            # below; that path goes to ~/.zshenv which is sourced before this
            # .zshrc file and before the direnv hook, making them immune to
            # direnv save/restore cycles regardless of when the dirs were created.)

              # Route managed development tools through the active direnv
              # environment, a rust-toolchain.toml project context (cargo/rustc
              # only), or the user-scoped default toolchain for repositories
            # that do not provide their own .envrc / nix develop entrypoint.
            __nucleus_run_managed_dev_tool() {
              _tool_name="$1"
              shift

              # direnv active: use the devShell tool if present in PATH; fall
              # through to NUCLEUS_DEFAULT_DEV_BIN otherwise so projects that
              # do not include the managed tool in their devShell still get
              # the baseline inventory.  Mirrors the PowerShell
              # Invoke-NucleusManagedDevTool availability-check pattern.
              # 2>/dev/null: command -v is read-only; failure means absent ← expected.
              if [[ -n "''${DIRENV_DIR:-}" ]] && command -v "$_tool_name" >/dev/null 2>&1; then
                command "$_tool_name" "$@"
                return $?
              fi

              # rust-toolchain.toml in the current directory → project context
              # for cargo/rustc.  rustup (default none) reads the toolchain file
              # and routes cargo/rustc to the pinned toolchain so project builds
              # work without a full devShell or direnv context.
              if [[ -f "''${PWD}/rust-toolchain.toml" ]] && command -v "$_tool_name" >/dev/null 2>&1; then
                case "$_tool_name" in
                  cargo|rustc)
                    command "$_tool_name" "$@"
                    return $?
                    ;;
                esac
              fi

              if [[ -n "''${NUCLEUS_DEFAULT_DEV_BIN:-}" && -x "''${NUCLEUS_DEFAULT_DEV_BIN}/$_tool_name" ]]; then
                "''${NUCLEUS_DEFAULT_DEV_BIN}/$_tool_name" "$@"
                return $?
              fi

              return 127
            }

            # prek: install repository-local Git hooks automatically on shell
            # startup and on each directory change for repos that opt in via
            # prek.toml. This keeps hook installation global and independent of
            # local direnv wiring.
            typeset -gA __nucleus_prek_checked_repos
            typeset -g __nucleus_prek_install_in_progress=0

            _prek_hooks_installed() {
              local repo_root="$1"
              local git_dir
              local hook_dir
              local hook_path

              # git rev-parse is a repo metadata probe; non-repo/permission
              # failures are expected here and handled by the return code.
              git_dir="$(git -C "$repo_root" rev-parse --git-dir 2>/dev/null)" || return 1
              [[ -n "$git_dir" ]] || return 1

              if [[ "$git_dir" != /* ]]; then
                git_dir="$repo_root/$git_dir"
              fi

              hook_dir="''${git_dir%/}/hooks"
              [[ -d "$hook_dir" ]] || return 1

              for hook_path in "$hook_dir"/*(.N); do
                if command grep -Fq '# File generated by prek' "$hook_path"; then
                  return 0
                fi
              done

              return 1
            }

            _prek_hook_install_if_needed() {
              local repo_root
              local install_status

              command -v git >/dev/null 2>&1 || return 0
              command -v prek >/dev/null 2>&1 || return 0

              # git rev-parse is a repo-membership probe; the expected stderr in
              # non-repository directories is intentionally suppressed.
              repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || return 0
              [[ -n "$repo_root" ]] || return 0
              [[ -f "$repo_root/prek.toml" ]] || return 0

              if [[ "$__nucleus_prek_install_in_progress" -eq 1 ]]; then
                return 0
              fi

              if [[ -n "''${__nucleus_prek_checked_repos[$repo_root]-}" ]]; then
                return 0
              fi

              if _prek_hooks_installed "$repo_root"; then
                __nucleus_prek_checked_repos[$repo_root]=1
                return 0
              fi

              __nucleus_prek_install_in_progress=1
              if (cd "$repo_root" && prek install); then
                __nucleus_prek_checked_repos[$repo_root]=1
              else
                install_status=$?
                echo "prek: failed to install hooks in $repo_root (exit $install_status)" >&2
              fi
              __nucleus_prek_install_in_progress=0

              return 0
            }

            autoload -Uz add-zsh-hook
            add-zsh-hook chpwd _prek_hook_install_if_needed
            _prek_hook_install_if_needed

            # Python/pip are only allowed when a scoped environment is active.
            # This keeps system Python protected while preserving normal venv/
            # conda workflows.
            __nucleus_python_scope_active() {
              [[ -n "''${VIRTUAL_ENV:-}" || -n "''${CONDA_PREFIX:-}" ]]
            }

            # Intercept python/python3 invocations and warn about system-wide Python ban.
            # These are functions, not aliases, so they can provide helpful context.
            python() {
              if __nucleus_python_scope_active; then
                command python "$@"
                return $?
              fi
              cat >&2 << 'EOF'
      shell: system-wide Python is banned to prevent accidental modifications.
               Use one of these approaches instead:
               - nix develop     (activate project devShell with scoped Python)
               - uv run <cmd>    (run Python via uv package manager)
               - uv venv         (create per-project venv managed by uv)
               - ./venv/bin/python (use pre-existing project venv)
      EOF
              return 1
            }

            python3() {
              if __nucleus_python_scope_active; then
                command python3 "$@"
                return $?
              fi
              python "$@"
            }

            # Intercept pip/pip3 invocations and warn about system-wide pip ban.
            # Remind users that modifying system Python breaks system dependencies.
            pip() {
              if __nucleus_python_scope_active; then
                command pip "$@"
                return $?
              fi
              cat >&2 << 'EOF'
      shell: system-wide pip is banned to prevent breaking system dependencies.
               Use one of these approaches instead:
               - nix develop     (activate project devShell with scoped Python+pip)
               - uv pip install  (use uv to manage project dependencies)
               - uv venv         (create per-project venv managed by uv)
               - ./venv/bin/pip  (use pre-existing project venv)
      EOF
              return 1
            }

            pip3() {
              if __nucleus_python_scope_active; then
                command pip3 "$@"
                return $?
              fi
              pip "$@"
            }

            # Intercept system-wide bun/cargo/rustc/uv invocations.
            # These tools are installed globally for system package management only:
            #   bun    — installs global Node/JS ecosystem system packages
            #   cargo  — cargo-binstall installs Rust binary system packages via rustup stable
            #   rustc  — companion to cargo; both come from the rustup-managed toolchain
            #   uv     — installs system-level Python tooling
            # Direct developer use of these system binaries is blocked.
            # When DIRENV_DIR is set, a project context is active:
            #   • 'use flake' .envrc: the devShell provides its own cargo/rustc;
            #     its scoped binaries shadow the system tools.
            # When a rust-toolchain.toml exists in the current directory, the same
            # pass-through applies for cargo/rustc: rustup reads the toolchain file
            # and routes cargo to the pinned toolchain so project builds work
            # without a full devShell or direnv context.
            bun() {
              __nucleus_run_managed_dev_tool bun "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed bun is unavailable right now.
               For development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
               Shell shortcuts ni/nr/nx also work inside a devShell.
      EOF
              return 1
            }

            cargo() {
              __nucleus_run_managed_dev_tool cargo "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed cargo is unavailable right now.
               For Rust development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or add a rust-toolchain.toml file to this directory
      EOF
              return 1
            }

            rustc() {
              __nucleus_run_managed_dev_tool rustc "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed rustc is unavailable right now.
               For Rust development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or add a rust-toolchain.toml file to this directory
      EOF
              return 1
            }

            uv() {
              __nucleus_run_managed_dev_tool uv "$@"
              _status=$?
              if [[ "$_status" -ne 127 ]]; then
                return "$_status"
              fi
              cat >&2 << 'EOF'
      shell: managed uv is unavailable right now.
               For Python development, use one of these managed entrypoints:
               - Enter a project directory with .envrc (direnv auto-loads the devShell)
               - Or use the user-scoped default toolchain installed by nucleus apply
      EOF
              return 1
            }
    ''
    + lib.optionalString pkgs.stdenv.isDarwin ''
            # macOS-only iCloud exclusion hooks.
            # WHY macOS-only: com.apple.fileprovider.ignore#P is a macOS FileProvider
            # xattr with no equivalent on NixOS/Windows.
            #
            # Trigger paths:
            #   1) chpwd hook: entering directories performs a best-effort recursive
            #      pass under iCloud-managed roots.
            #   2) mkdir wrapper: newly created matching directories are marked
            #      immediately.
            #   3) precmd hook: after each command, checks immediate children of
            #      $PWD (depth 1) for newly created excluded dirs.  This catches
            #      tools like npm install, git clone, pip install that create
            #      directories via syscalls without using mkdir.
            #
            # Existing directories are also covered by the activation-time recursive
            # pass in modules/macos.nix.
            typeset -ga __nucleus_icloud_excluded_names=(
      ${lib.concatMapStringsSep "\n" (name: "        ${lib.escapeShellArg name}") iCloudExcludedDirNames}
            )

            __nucleus_is_icloud_managed_path() {
              local candidate_path="$1"
              case "$candidate_path" in
                ${
                  lib.concatMapStringsSep "|" (root: "\"$HOME/${root}\"|\"$HOME/${root}/\"*") iCloudManagedRoots
                })
                  return 0
                  ;;
              esac
              return 1
            }

            __nucleus_check_icloud_exclusion() {
              local target_path="$1"
              local normalized_path
              local current_mark
              local target_name

              if [[ "$target_path" == /* ]]; then
                normalized_path="$target_path"
              else
                normalized_path="$PWD/$target_path"
              fi
              normalized_path="''${normalized_path%/}"

              __nucleus_is_icloud_managed_path "$normalized_path" || return 0

              target_name=$(basename "$normalized_path")

              for excluded in "''${__nucleus_icloud_excluded_names[@]}"; do
                if [[ "$target_name" == "$excluded" ]]; then
                  # Missing xattr is expected for newly created paths, so probe the
                  # value quietly and only log when we actually mutate state.
                  current_mark="$(
                    /usr/bin/xattr -p com.apple.fileprovider.ignore#P "$normalized_path" 2>/dev/null
                  )" || true
                  if [[ "$current_mark" == "1" ]]; then
                    return 0
                  fi

                  if /usr/bin/xattr -w com.apple.fileprovider.ignore#P 1 "$normalized_path"; then
                    echo "shell: iCloud exclusion marked $normalized_path" >&2
                  else
                    echo "shell: failed to mark iCloud exclusion for $normalized_path" >&2
                  fi
                  return 0
                fi
              done
              return 0
            }

            __nucleus_mark_icloud_exclusions_under() {
              local root_path="$1"

              __nucleus_is_icloud_managed_path "$root_path" || return 0
              [[ "''${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0

              # Build find predicate with -prune to stop recursion into excluded dirs.
              # Pattern: ( -name A -prune -o -name B -prune -o ... -o -type d )
              # This avoids descending into node_modules, .venv, etc. during interactive
              # chpwd hook, which would freeze the terminal for 10+ seconds on large repos.
              local -a __icloud_find_args
              __icloud_find_args=()
              local __icloud_n=0
              local __icloud_name
              for __icloud_name in "''${__nucleus_icloud_excluded_names[@]}"; do
                if [[ $__icloud_n -eq 0 ]]; then
                  __icloud_find_args+=( "(" "-name" "$__icloud_name" "-prune" )
                else
                  __icloud_find_args+=( "-o" "-name" "$__icloud_name" "-prune" )
                fi
                __icloud_n=$(( __icloud_n + 1 ))
              done
              # Final -type d to match any non-excluded directory.
              __icloud_find_args+=( "-o" "-type" "d" ")" )

              local __candidate
              while IFS= read -r __candidate; do
                __nucleus_check_icloud_exclusion "$__candidate"
              done < <(/usr/bin/find "$root_path" "''${__icloud_find_args[@]}" 2>/dev/null)

              return 0
            }

            __nucleus_check_icloud_exclusions_on_pwd_change() {
              [[ "''${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0
              __nucleus_mark_icloud_exclusions_under "$PWD"
            }

            autoload -Uz add-zsh-hook
            add-zsh-hook chpwd __nucleus_check_icloud_exclusions_on_pwd_change
            __nucleus_check_icloud_exclusions_on_pwd_change

            # Lightweight precmd check: scans only immediate children of $PWD (-maxdepth 1)
            # so tools that create excluded directories without mkdir (npm install,
            # git clone, pip install, etc.) get marked promptly.  Unlike the chpwd
            # hook, this must be fast — it runs after every command.
            __nucleus_check_icloud_exclusions_immediate() {
              [[ "''${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0
              local __candidate
              while IFS= read -r __candidate; do
                __nucleus_check_icloud_exclusion "$__candidate"
              done < <(/usr/bin/find "$PWD" -maxdepth 1 -type d 2>/dev/null)
            }

            add-zsh-hook precmd __nucleus_check_icloud_exclusions_immediate

            # Override mkdir to check for excluded directories after creation.
            mkdir() {
              /bin/mkdir "$@"
              local _mkdir_status=$?

              # Only process if mkdir succeeded and we're not in dry-run mode.
              if [[ $_mkdir_status -eq 0 ]]; then
                for arg in "$@"; do
                  # Skip option flags (starting with -)
                  if [[ ! "$arg" =~ ^- ]]; then
                    # Check if the path exists (was created successfully)
                    if [[ -d "$arg" ]]; then
                      __nucleus_check_icloud_exclusion "$arg"
                    fi
                  fi
                done
              fi

              return $_mkdir_status
            }
    '';
  };

  # User-scope package manager bin directories declared unconditionally so PATH
  # is stable across direnv activation/deactivation cycles regardless of
  # whether the directories existed at shell startup time.
  # home.sessionPath writes to ~/.zshenv (via the HM session-vars mechanism)
  # which is sourced before ~/.zshrc (where the direnv hook lives), so these
  # entries are always part of the "original" PATH state that direnv saves and
  # restores — fixing the reliability issue of .zshrc-based PATH guards that
  # only run once at startup.
  #   bun install -g   → ~/.bun/bin   (BUN_INSTALL_BIN default)
  #   cargo-binstall   → ~/.cargo/bin  (CARGO_HOME/bin default)
  #   uv tool install  → ~/.local/bin  (XDG_BIN_HOME default)
  # Sources:
  # https://bun.sh/docs/cli/install#global-packages
  # https://doc.rust-lang.org/cargo/commands/cargo-install.html
  # https://docs.astral.sh/uv/reference/settings/#tool-bin-dir
  home.sessionPath = [
    "${config.home.homeDirectory}/.bun/bin"
    "${config.home.homeDirectory}/.cargo/bin"
    "${config.home.homeDirectory}/.local/bin"
  ];

  home.sessionVariables = mergedSessionVariables;

  # Global bun configuration: set a 5-day minimum release age for all package
  # installs (bun install -g, bun add, etc.). Bun reads bunfig.toml from $HOME
  # by default.
  # Source: https://bun.sh/docs/runtime/bunfig#install
  # Global bun configuration: set a 5-day minimum release age for all package
  # installs (bun install -g, bun add, etc.) and enable exact version pinning
  # in package.json (no caret ranges). Bun reads bunfig.toml from $HOME by default.
  # Source: https://bun.sh/docs/runtime/bunfig#install
  home.file.".bunfig.toml" = {
    text = ''
      [install]
      exact = true
      linker = "isolated"
      minimumReleaseAge = 432000
    '';
  };

  # ---------------------------------------------------------------------------
  # nix-direnv _nix override: filter apple-sdk vars from print-dev-env output
  # ---------------------------------------------------------------------------
  # apple-sdk's nix-support/setup-hook exports DEVELOPER_DIR, SDKROOT, and
  # NIX_APPLE_SDK_VERSION during nix print-dev-env evaluation.  These vars enter
  # direnv's managed environment set via the profile.rc that nix-direnv caches.
  # When you leave a direnv-managed directory, direnv strips all managed vars,
  # breaking xcrun until the next login shell re-sources hm-session-vars.
  #
  # This direnvrc overrides _nix() to filter those three variables from the
  # print-dev-env stdout before nix-direnv caches them.  They never enter the
  # managed set, so they survive directory transitions (either from hm-session-vars
  # or not at all, depending on the shell startup path).
  #
  # direnv auto-sources ~/.config/direnv/lib/*.sh before ~/.config/direnv/direnvrc
  # and before the .envrc.  Since nix-direnv defines _nix in lib/hm-nix-direnv.sh,
  # our override in direnvrc takes effect before the .envrc calls use_flake.
  # The _nix_direnv_nix variable is set by nix-direnv's _nix_direnv_preflight()
  # at the start of use_flake, so referencing it from the override is safe.
  home.file.".config/direnv/direnvrc" = {
    text = ''
      _nix() {
        local _has_pe=0
        for _arg in "$@"; do
          if [[ "$_arg" == "print-dev-env" ]]; then
            _has_pe=1
            break
          fi
        done
        if [[ $_has_pe -eq 1 ]]; then
          "''${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@" \
            | command grep -v -E '^(DEVELOPER_DIR=|SDKROOT=|NIX_APPLE_SDK_VERSION=)|^export (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$|^unset (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$'
        else
          "''${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
        fi
      }
    '';
  };

  # Global uv configuration: exact pinning and supply-chain hardening.
  # uv reads uv.toml from $XDG_CONFIG_HOME/uv/uv.toml (~/.config/uv/uv.toml).
  # Source: https://docs.astral.sh/uv/reference/settings/#add-bounds
  # Source: https://docs.astral.sh/uv/reference/settings/#exclude-newer
  home.file."${config.xdg.configHome}/uv/uv.toml" = {
    text = ''
      add-bounds = "exact"
      exclude-newer = "P5D"
    '';
  };

  # ---------------------------------------------------------------------------
  # installZshCompletions
  # Idempotently generates zsh completion files for CLI tools whose Nix packages
  # do not auto-bundle them into fpath, writing into the writable user-local
  # completion directory created in initContent.
  #
  # For each tool with a completion subcommand (bat, gh, uv, etc.), this step:
  #   * Probes the tool binary directly from the Nix store (no PATH dependency).
  #   * Skips regeneration if the completion file exists and is newer than the
  #     tool binary (mtime freshness check).
  #   * Fails gracefully if a completion subcommand exits non-zero (|| true).
  #
  # Why after installCargoBinstallPackages: all Nix and non-Nix package managers
  # (bun, uv, cargo-binstall) have converged by that point, so every tool binary
  # that could provide completions is present before we try to generate them.
  # ---------------------------------------------------------------------------
  home.activation = {
    installZshCompletions = lib.hm.dag.entryAfter [ "installCargoBinstallPackages" ] ''
      set -eu

      _zsh_comp_dir="$HOME/.local/share/zsh/completions"
      mkdir -p "$_zsh_comp_dir"

      # Generate completion file for a tool if the file is absent or stale.
      # Args: <binary-path> <completion-file> <shell-command>
      _generate_if_stale() {
        local _bin_path="$1"
        local _comp_file="$2"
        local _gen_cmd="$3"

        if [ -f "$_comp_file" ] && [ "$_comp_file" -nt "$_bin_path" ]; then
          return 0  # already current, skip
        fi

        echo "zsh-completions: generating ''${_comp_file##*/}"
        mkdir -p "$(dirname "$_comp_file")"
        eval "$_gen_cmd" > "$_comp_file" 2>/dev/null || {
          echo "  (failed, skipping)" >&2
          rm -f "$_comp_file"
        }
      }

      # -----------------------------------------------------------------------
      # Tool completion table
      # Each entry probes the Nix store path directly so PATH state (which
      # changes during activation) does not matter.
      #
      # Selection rationale:
      #   * Include every nucleus-provisioned CLI tool whose Nix package MAY
      #     not bundle zsh completions into fpath.
      #   * Rely on || true to skip tools whose subcommand is absent or broken.
      #   * Omitted: git (bundled), direnv/zoxide (HM integration handles them),
      #     nix (bundled), fzf (source-based, not file-based).
      # -----------------------------------------------------------------------
      _generate_if_stale \
        "${pkgs.bat}/bin/bat" \
        "$_zsh_comp_dir/_bat" \
        "'${pkgs.bat}/bin/bat' --completion zsh"

      _generate_if_stale \
        "${pkgs.bun}/bin/bun" \
        "$_zsh_comp_dir/_bun" \
        "'${pkgs.bun}/bin/bun' completions"

      # cargo-binstall skipped: --completion flag not supported in current
      # version (confirmed 2026-07-01). No replacement available.
      #_generate_if_stale \
      #  "${pkgs.cargo-binstall}/bin/cargo-binstall" \
      #  "$_zsh_comp_dir/_cargo-binstall" \
      #  "'${pkgs.cargo-binstall}/bin/cargo-binstall' --completion zsh"

      # eza skipped: --generate-completion / --completion flags not supported
      # in current version (confirmed 2026-07-01). No replacement available.
      #_generate_if_stale \
      #  "${pkgs.eza}/bin/eza" \
      #  "$_zsh_comp_dir/_eza" \
      #  "'${pkgs.eza}/bin/eza' --generate-completion zsh"

      _generate_if_stale \
        "${pkgs.fd}/bin/fd" \
        "$_zsh_comp_dir/_fd" \
        "'${pkgs.fd}/bin/fd' --gen-completions zsh"

      _generate_if_stale \
        "${pkgs.gh}/bin/gh" \
        "$_zsh_comp_dir/_gh" \
        "'${pkgs.gh}/bin/gh' completion -s zsh"

      _generate_if_stale \
        "${pkgs.opencode}/bin/opencode" \
        "$_zsh_comp_dir/_opencode" \
        "'${pkgs.opencode}/bin/opencode' completion zsh"

      # prek skipped: no completion subcommand exists in current version
      # (confirmed 2026-07-01). "prek completion zsh" is interpreted as hook
      # selectors, not a completion command.
      #_generate_if_stale \
      #  "${pkgs.prek}/bin/prek" \
      #  "$_zsh_comp_dir/_prek" \
      #  "'${pkgs.prek}/bin/prek' completion zsh"

      _generate_if_stale \
        "${pkgs.ruff}/bin/ruff" \
        "$_zsh_comp_dir/_ruff" \
        "'${pkgs.ruff}/bin/ruff' generate-shell-completion zsh"

      _generate_if_stale \
        "${pkgs.rustup}/bin/rustup" \
        "$_zsh_comp_dir/_rustup" \
        "'${pkgs.rustup}/bin/rustup' completions zsh"

      _generate_if_stale \
        "${pkgs.typst}/bin/typst" \
        "$_zsh_comp_dir/_typst" \
        "'${pkgs.typst}/bin/typst' completions zsh"

      _generate_if_stale \
        "${pkgs.uv}/bin/uv" \
        "$_zsh_comp_dir/_uv" \
        "'${pkgs.uv}/bin/uv' generate-shell-completion zsh"

      # -----------------------------------------------------------------------
      # Nucleus-command completions: static zsh completion files shipped with
      # the repository. Copied directly (no generation needed).
      # -----------------------------------------------------------------------
      _zsh_nucleus_comp_src="${./completions/zsh}"
      for _zsh_nuc_f in "$_zsh_nucleus_comp_src"/_nucleus-* "$_zsh_nucleus_comp_src"/_nucleus; do
        [ -f "$_zsh_nuc_f" ] || continue
        cp -f "$_zsh_nuc_f" "$_zsh_comp_dir/"
      done
      unset _zsh_nucleus_comp_src _zsh_nuc_f

      echo "zsh-completions: done"
    '';
  };
}
