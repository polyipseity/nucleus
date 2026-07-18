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
  username,
  nucleusApps,
  users ? null,
  ...
}:
let
  # Dedicated alias/env fragments keep list-like attrsets isolated so sort order
  # can be audited without scanning unrelated shell options.
  shellAliases = import ./shell/aliases.nix { };
  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVarsHelpers = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  # Single source of truth for AI agent session detection.  Shared with
  # pwsh.nix and Sync-ShellProfile.ps1 (Windows).
  agentEnv = import ./agent-env-vars.nix;

  # All env vars are sourced from the centralized catalog.
  mergedSessionVariables = envVarsHelpers.allVars;

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
    initContent =
      builtins.replaceStrings
        [ "__AGENT_ENV_VAR_CHECKS__" "__AGENT_DEVIN_PATH__" "__DEFAULT_DEV_TOOLS_PATH__" ]
        [
          (lib.concatStringsSep "\n" (
            map (v: "  [[ -n \"\${${v}:-}\" ]] && return 0") agentEnv.agentEnvVarNames
          ))
          agentEnv.devinPosixPath
          managedPaths.defaultDevTools
        ]
        (builtins.readFile ../scripts/shell/init.zsh)
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
                      # undoc-supp: xattr may not be set yet on newly created path; absence is not an error — the check below gates on value "1".
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

  # User-scope package manager bin directories from the centralized catalog.
  # home.sessionPath writes to ~/.zshenv (via the HM session-vars mechanism)
  # which is sourced before ~/.zshrc (where the direnv hook lives), so these
  # entries are always part of the "original" PATH state that direnv saves and
  # restores — fixing the reliability issue of .zshrc-based PATH guards that
  # only run once at startup.
  # Sources: see pathComponents in src/modules/lib/managed-paths.nix.
  #   Prepends:    (before system default PATH)
  #   Appends:     bun install -g   → ~/.bun/bin   (BUN_INSTALL_BIN default)
  #                cargo-binstall   → ~/.cargo/bin  (CARGO_HOME/bin default)
  #                uv tool install  → ~/.local/bin  (XDG_BIN_HOME default)
  # Sole declaration site for home.sessionPath and home.sessionVariables.
  # No other file sets these — all env vars flow through the centralized
  # catalog in src/modules/lib/env-catalog.nix.
  home.sessionPath =
    (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.prepend)
    ++ (builtins.map (p: "${config.home.homeDirectory}/${p}") managedPaths.pathComponents.append);

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
    # Method 1 (writable symlink): repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/bun/bunfig.toml";
  };

  # Global Cargo configuration: per-platform linker selection.
  # Cargo evaluates cfg(target_os = "...") against the host build target at
  # config-load time — non-matching sections are silently ignored.
  #
  #   Linux   → mold via clang -fuse-ld=mold (fastest ELF linker)
  #   macOS   → native Apple ld64 via cc     (system default, explicit for clarity)
  #   Windows → rust-lld bundled with Rust    (zero-install, lld-link)
  home.file.".cargo/config.toml" = {
    # Method 1 (writable symlink): repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/cargo/config.toml";
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
    # Method 1 (writable symlink): repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/direnv/direnvrc";
  };

  # Global uv configuration: exact pinning and supply-chain hardening.
  # uv reads uv.toml from $XDG_CONFIG_HOME/uv/uv.toml (~/.config/uv/uv.toml).
  # Source: https://docs.astral.sh/uv/reference/settings/#add-bounds
  # Source: https://docs.astral.sh/uv/reference/settings/#exclude-newer
  home.file."${config.xdg.configHome}/uv/uv.toml" = {
    # Method 1 (writable symlink): repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/uv/uv.toml";
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
  #   * Fails gracefully if a completion subcommand exits non-zero (soft-fail).
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
      #   * Rely on soft-fail to skip tools whose subcommand is absent or broken.
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
