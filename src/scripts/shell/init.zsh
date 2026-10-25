# Zsh initialization for nucleus-managed hosts. History exclusion, stale
# nix-env scrubber, completion directory, agent-session detection, dev tool
# interception, srt agent wrapping.
# Embedded by src/modules/shell/default.nix into initContent.

# Scrub once per shell start when the env this shell inherited carries nix
# store paths that were garbage-collected: a devShell env outlives its
# closure in long-lived shells, tmux panes, and IDE terminals, and every
# reference then dies with "library not found for -lSystem". Repo-managed
# values route through stable toolchains/ symlinks (converged at activation)
# and cannot go stale; the residue is devShell stdenv exports like NIX_CC and
# flag vars, which only re-entering the devShell can restore.
# WHY repair instead of the previous warn-only guard: dropping a dead value
# turns a broken build into a working one on the system toolchain, and the
# report still names everything dropped so the devShell case is never silent.
# No Windows twin because Windows has no nix devShell env to go stale.
if [[ -z "${__nucleus_stale_nix_warned:-}" ]]; then
  typeset -g __nucleus_stale_nix_warned=1
  () {
    # _nucleus_dead_component PATH: 0 when PATH is a /nix/store component
    # whose store-hash segment names an entry that no longer exists.
    _nucleus_dead_component() {
      local _ndc_comp="$1"
      [[ "$_ndc_comp" == /nix/store/* ]] || return 1
      local _ndc_head="${_ndc_comp#/nix/store/}"
      _ndc_head="${_ndc_head%%/*}"
      # Hash shape comes from the enclosing scope's single __nuc_hash_re.
      [[ "$_ndc_head" =~ $__nuc_hash_re ]] || return 1
      [[ ! -e "$_ndc_comp" ]]
    }

    local -a __nuc_report
    __nuc_report=()
    local __nuc_nixdropped=false
    local __nuc_toolchain_dropped=false
    # Toolchain vars that were (pre-fix) raw /nix/store paths; a dead one means
    # the stable symlinks were never converged -> run nucleus-apply.
    local -A __nuc_toolchain_vars
    __nuc_toolchain_vars=(
      CC 1 CXX 1 LD 1 DEVELOPER_DIR 1 SDKROOT 1 LIBRARY_PATH 1
      NIX_SSL_CERT_FILE 1 CMAKE_C_COMPILER_LAUNCHER 1 CMAKE_CXX_COMPILER_LAUNCHER 1
    )
    # One hash-shape gate for both passes: a /nix/store segment that is not a
    # store hash is never ours to touch.
    local __nuc_hash_re='^[0-9a-z]{32}([-.].*)?$'

    # Colon-list vars: drop dead components, keep the rest in order, dedupe
    # entries that repeat, and leave the variable untouched when nothing was
    # dead. The list is declared once and shared with the scalar pass below.
    local -a __nuc_colon_vars
    __nuc_colon_vars=(
      PATH MANPATH LD_LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
      OBJC_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH PYTHONPATH PERL5LIB
      TERMINFO_DIRS
    )
    typeset -A __nuc_colon_set
    __nuc_colon_set=()
    local __nuc_cv
    for __nuc_cv in "${__nuc_colon_vars[@]}"; do
      __nuc_colon_set[$__nuc_cv]=1
    done

    local __nuc_var __nuc_raw __nuc_comp __nuc_dropped __nuc_total
    local -a __nuc_kept
    typeset -A __nuc_seen
    for __nuc_var in "${__nuc_colon_vars[@]}"; do
      __nuc_raw="${(P)__nuc_var}"
      [[ -n "$__nuc_raw" ]] || continue
      __nuc_kept=()
      __nuc_seen=()
      __nuc_dropped=0
      __nuc_total=0
      for __nuc_comp in "${(@s/:/)__nuc_raw}"; do
        (( __nuc_total++ ))
        if _nucleus_dead_component "$__nuc_comp"; then
          (( __nuc_dropped++ ))
          continue
        fi
        if [[ -z "$__nuc_comp" ]]; then
          __nuc_kept+=( "" )
        elif [[ -z "${__nuc_seen[$__nuc_comp]+x}" ]]; then
          __nuc_seen[$__nuc_comp]=1
          __nuc_kept+=( "$__nuc_comp" )
        fi
      done
      if (( __nuc_dropped > 0 )); then
        export "${__nuc_var}=${(j/:/)__nuc_kept}"
        __nuc_report+=( "$__nuc_var ($__nuc_dropped of $__nuc_total entries)" )
        [[ "$__nuc_var" == NIX_* ]] && __nuc_nixdropped=true
        [[ -n "${__nuc_toolchain_vars[$__nuc_var]+x}" ]] && __nuc_toolchain_dropped=true
      fi
    done

    # Other exported ordinary scalars: a dead store path anywhere in the
    # value means the value is broken as a whole, so unset it and report.
    # The bare /nix/store/<hash>-<name> directory is re-checked before
    # unsetting: an over-long extraction whose store entry still exists is
    # ambiguous, and unsetting a live value would break more than it heals.
    local -a __nuc_names
    local __nuc_name __nuc_type __nuc_value __nuc_rest __nuc_cand __nuc_head
    local __nuc_bare
    # The [@] subscript is load-bearing: ${(k)parameters} without it joins
    # every key into one word, and the loop then matches nothing.
    __nuc_names=("${(k)parameters[@]}")
    for __nuc_name in "${(@o)__nuc_names}"; do
      case "$__nuc_name" in
      __nucleus_* | __nuc_* | _ | parameters) continue ;;
      esac
      [[ -n "${__nuc_colon_set[$__nuc_name]+x}" ]] && continue
      __nuc_type="${parameters[$__nuc_name]}"
      # zsh spells the export flag "export" inside type strings like
      # "scalar-export"; "exported" never matches. Special and tied params
      # (HOME is "scalar-export-special", PATH "scalar-tied-export-special")
      # are runtime state the shell manages: unsetting a dead HOME would
      # break the completion-dir mkdir below at every shell start.
      [[ "$__nuc_type" == *export* ]] || continue
      if [[ "$__nuc_type" == *readonly* || "$__nuc_type" == *association* ||
        "$__nuc_type" == *array* || "$__nuc_type" == *function* ||
        "$__nuc_type" == *special* || "$__nuc_type" == *tied* ]]; then
        continue
      fi
      __nuc_value="${(P)__nuc_name}"
      [[ "$__nuc_value" == *'/nix/store/'* ]] || continue
      __nuc_rest="$__nuc_value"
      while [[ "$__nuc_rest" == *'/nix/store/'* ]]; do
        __nuc_rest="${__nuc_rest#*/nix/store/}"
        __nuc_cand="/nix/store/${__nuc_rest%%[[:space:]:\"\(\)]*}"
        __nuc_head="${__nuc_cand#/nix/store/}"
        __nuc_head="${__nuc_head%%/*}"
        # Same hash-shape gate as the colon pass, so a nonexistent but
        # non-hash /nix/store segment is not enough to unset a scalar.
        [[ "$__nuc_head" =~ $__nuc_hash_re ]] || continue
        __nuc_bare="/nix/store/$__nuc_head"
        if [[ ! -e "$__nuc_bare" ]]; then
          unset "$__nuc_name"
          __nuc_report+=( "$__nuc_name=$__nuc_cand" )
          [[ "$__nuc_name" == NIX_* ]] && __nuc_nixdropped=true
          [[ -n "${__nuc_toolchain_vars[$__nuc_name]+x}" ]] && __nuc_toolchain_dropped=true
          break
        fi
      done
    done

    if (( ${#__nuc_report} > 0 )); then
      # -r keeps inherited values from being interpreted as print escapes
      # (a \c in a report value would truncate the line).
      print -ru2 -- "this shell inherited nix store paths that no longer exist; dropped: ${(j/, /)__nuc_report}"
      if [[ "$__nuc_nixdropped" == true ]]; then
        print -ru2 -- "those devShell tools are gone; re-enter the devShell (direnv reload, or exit and re-enter) to restore them."
      fi
      if [[ "$__nuc_toolchain_dropped" == true ]]; then
        print -ru2 -- "toolchain paths are stale; run nucleus-apply to converge stable symlinks."
      fi
    fi
    unfunction _nucleus_dead_component
  }
fi

# History: exclude commands starting with a space and duplicates
setopt HIST_IGNORE_SPACE
setopt HIST_IGNORE_DUPS

# Writable user-local completion directory
typeset -g ZSH_COMPLETION_DIR="$HOME/.local/share/zsh/completions"
mkdir -p "$ZSH_COMPLETION_DIR"
fpath+=("$ZSH_COMPLETION_DIR")

# WHY the fallback: Home Manager's fpath points at read-only Nix store paths, so
# `gh completion -s zsh > file` cannot write there.
compinit -C -i -d "$HOME/.zcompdump"

# AI agent session detection
__nucleus_is_agent_session() {
__AGENT_ENV_VAR_CHECKS__
  [[ -d __AGENT_DEVIN_PATH__ ]] && return 0
  return 1
}

# Interactive-feature suppression in AI agent sessions
if __nucleus_is_agent_session; then
  unsetopt ZLE
  PS2=""
  PS1="%% "
fi

# pay-respects shell hook. Skipped in non-interactive and agent sessions, where
# its prompt would block with no user to answer.
# WHY eval and not an alias: `pay-respects zsh --alias` defines a zsh FUNCTION
# `f` that captures history and evals the correction, and a zsh alias would shadow
# it, leaving a bare binary invocation that neither fixes nor records.
if [[ -o interactive ]] && ! __nucleus_is_agent_session; then
  eval "$(pay-respects zsh --alias)"
fi

# Starship prompt
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# User-scope bin dirs go through home.sessionPath (~/.zshenv, sourced before
# this file and before the direnv hook), so they survive save/restore cycles.
__nucleus_run_managed_dev_tool() {
  _tool_name="$1"
  shift

  # WHY fall through: a devShell that omits the managed tool still gets the
  # baseline inventory. Mirrors Invoke-NucleusManagedDevTool on Windows.
  if [[ -n "${DIRENV_DIR:-}" ]] && command -v "$_tool_name" >/dev/null 2>&1; then
    command "$_tool_name" "$@"
    return $?
  fi

  # WHY rust-toolchain.toml: rustup (default none) reads it and routes cargo/rustc
  # to the pinned toolchain, so a project builds without a devShell.
  if [[ -f "${PWD}/rust-toolchain.toml" ]] && command -v "$_tool_name" >/dev/null 2>&1; then
    case "$_tool_name" in
      cargo|rustc)
        command "$_tool_name" "$@"
        return $?
        ;;
    esac
  fi

  if [[ -x "__DEFAULT_DEV_TOOLS_PATH__/bin/$_tool_name" ]]; then
    "__DEFAULT_DEV_TOOLS_PATH__/bin/$_tool_name" "$@"
    return $?
  fi

  return 127
}

# prek installs repo-local Git hooks on startup and on each directory change,
# for repos that opt in via prek.toml.
typeset -gA __nucleus_prek_checked_repos
typeset -g __nucleus_prek_install_in_progress=0

_prek_hook_install_if_needed() {
  local repo_root
  local install_status

  command -v git >/dev/null 2>&1 || return 0
  command -v prek >/dev/null 2>&1 || return 0

  # git rev-parse probes repo membership; expected stderr outside a repo is
  # intentionally suppressed.
  repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$repo_root" ]] || return 0
  [[ -f "$repo_root/prek.toml" ]] || return 0

  if [[ "$__nucleus_prek_install_in_progress" -eq 1 ]]; then
    return 0
  fi

  if [[ -n "${__nucleus_prek_checked_repos[$repo_root]-}" ]]; then
    return 0
  fi

  __nucleus_prek_install_in_progress=1
  if (cd "$repo_root" && prek install --quiet); then
    __nucleus_prek_checked_repos[$repo_root]=1
  else
    install_status=$?
    echo "prek: error: failed to install hooks in $repo_root (exit $install_status)" >&2
    __nucleus_prek_checked_repos[$repo_root]=1
  fi
  __nucleus_prek_install_in_progress=0

  return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _prek_hook_install_if_needed
_prek_hook_install_if_needed

# Python/pip are allowed only under a scoped environment, or when the binary is
# the nix-managed pkgs.python3 from this repo (realpath /nix/store/*).
__nucleus_python_scope_active() {
  [[ -n "${VIRTUAL_ENV:-}" || -n "${CONDA_PREFIX:-}" ]]
}

python() {
  if __nucleus_python_scope_active; then
    command python "$@"
    return $?
  fi
  # whence -p resolves the real binary, unlike command -v which can return the
  # function name when a function shadows the command.
  local _nucleus_python_real
  _nucleus_python_real="$(realpath "$(whence -p python 2>/dev/null)" 2>/dev/null)" || _nucleus_python_real=""
  if [[ "$_nucleus_python_real" == /nix/store/* ]]; then
    command python "$@"
    return $?
  fi
  cat >&2 << 'EOF'
shell: error: system-wide Python is banned to prevent accidental modifications.
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
  # fall through to python() for final resolution (scoped/ban)
  local _nucleus_python3_real
  _nucleus_python3_real="$(realpath "$(whence -p python3 2>/dev/null)" 2>/dev/null)" || _nucleus_python3_real=""
  if [[ "$_nucleus_python3_real" == /nix/store/* ]]; then
    command python3 "$@"
    return $?
  fi
  python "$@"
}

# pip is banned system-wide: it breaks system dependencies.
pip() {
  if __nucleus_python_scope_active; then
    command pip "$@"
    return $?
  fi
  cat >&2 << 'EOF'
shell: error: system-wide pip is banned to prevent breaking system dependencies.
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

# bun, cargo, rustc, and uv exist here for system package management only:
#   bun    installs global Node/JS system packages
#   cargo  cargo-binstall installs Rust system binaries via rustup stable
#   rustc  companion to cargo, from the same rustup toolchain
#   uv     installs system-level Python tooling
# Direct developer use routes through an active direnv or, for cargo/rustc, a
# rust-toolchain.toml in the current directory.
bun() {
  __nucleus_run_managed_dev_tool bun "$@"
  _status=$?
  if [[ "$_status" -ne 127 ]]; then
    return "$_status"
  fi
  cat >&2 << 'EOF'
shell: warning: managed bun is unavailable right now.
         For development, use one of these managed entrypoints:
         - Enter a project directory with .envrc (direnv auto-loads the devShell)
         - Or use the user-scoped default toolchain installed by nucleus apply
         Shell shortcuts -n* (bun) also work inside a devShell.
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
shell: warning: managed cargo is unavailable right now.
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
shell: warning: managed rustc is unavailable right now.
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
shell: warning: managed uv is unavailable right now.
         For Python development, use one of these managed entrypoints:
         - Enter a project directory with .envrc (direnv auto-loads the devShell)
         - Or use the user-scoped default toolchain installed by nucleus apply
EOF
  return 1
}

# Sandbox-runtime (srt) agent wrapping. pi runs in srt by default;
# pi-unrestricted bypasses the sandbox. vscode and cursor are excluded: they
# have built-in protections and no srt needed.
pi() {
  command -v srt >/dev/null 2>&1 || { echo "error: srt (sandbox-runtime) is required but not installed. Run 'nucleus-apply' to install it." >&2; return 1; }
  # WHY: srt parses its own options (-h, -V, -d, -s, -c, --control-fd) wherever
  #      they appear, so without "--" a plain `pi --help` prints srt's help and
  #      `pi -c <arg>` loses the argument without an error.
  srt command pi -- "$@"
}

pi-unrestricted() {
  command pi "$@"
}

# npm, npx, node, and corepack are not installed here; bun is the sole JS
# runtime and package manager. No DIRENV_DIR pass-through: no devShell in this
# repo provides them.
npm() {
  cat >&2 << 'EOF'
shell: error: system-wide npm is not used in this environment.
         Use bun equivalents instead:
         - bun install     (install packages)
         - bun add <pkg>   (add a dependency)
         - bun x <cmd>     (run one-shot package commands, replaces npx)
         - bun run         (run package.json scripts)
         Shell shortcuts -n* (bun) also work.
EOF
  return 1
}

npx() {
  cat >&2 << 'EOF'
shell: error: system-wide npx is not used in this environment.
         Use bun x <cmd> for one-shot package execution instead.
EOF
  return 1
}

node() {
  cat >&2 << 'EOF'
shell: error: system-wide Node.js is not used in this environment.
         Use bun as the JavaScript runtime instead:
         - bun <script>   (run a script)
         - bun run        (run package.json scripts)
EOF
  return 1
}

corepack() {
  cat >&2 << 'EOF'
shell: error: corepack is not used in this environment.
         Use bun for package management instead.
EOF
  return 1
}

__MACOS_ICLOUD_HOOKS__
