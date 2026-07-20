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
__AGENT_ENV_VAR_CHECKS__
  [[ -d __AGENT_DEVIN_PATH__ ]] && return 0
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
  # through to the managed default toolchain otherwise so projects
  # that do not include the managed tool in their devShell still get
  # the baseline inventory.  Mirrors the PowerShell
  # Invoke-NucleusManagedDevTool availability-check pattern.
  # 2>/dev/null: command -v is read-only; failure means absent ← expected.
  if [[ -n "${DIRENV_DIR:-}" ]] && command -v "$_tool_name" >/dev/null 2>&1; then
    command "$_tool_name" "$@"
    return $?
  fi

  # rust-toolchain.toml in the current directory → project context
  # for cargo/rustc.  rustup (default none) reads the toolchain file
  # and routes cargo/rustc to the pinned toolchain so project builds
  # work without a full devShell or direnv context.
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

  hook_dir="${git_dir%/}/hooks"
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

  if [[ -n "${__nucleus_prek_checked_repos[$repo_root]-}" ]]; then
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

# Python/pip are only allowed when a scoped environment is active,
# OR when the binary is a nix-managed Python from this repo
# (pkgs.python3 at a /nix/store/* realpath). Outside those cases,
# the python/python3 functions show the educational ban message.
__nucleus_python_scope_active() {
  [[ -n "${VIRTUAL_ENV:-}" || -n "${CONDA_PREFIX:-}" ]]
}

# Intercept python invocations: pass through only to nix-managed
# Python (pkgs.python3 from this repo, realpath /nix/store/*).
# Everything else triggers the educational ban message.
python() {
  if __nucleus_python_scope_active; then
    command python "$@"
    return $?
  fi
  # Only pass through nix-managed Python from this repo (pkgs.python3).
  # whence -p resolves the actual binary path, unlike command -v which can
  # return the shell function name when a function shadows the command.
  local _nucleus_python_real
  _nucleus_python_real="$(realpath "$(whence -p python 2>/dev/null)" 2>/dev/null)" || _nucleus_python_real=""
  if [[ "$_nucleus_python_real" == /nix/store/* ]]; then
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

# Intercept python3 invocations: pass through only to nix-managed
# Python 3 (pkgs.python3 from this repo, realpath /nix/store/*).
# Everything else falls through to python() for final resolution.
python3() {
  if __nucleus_python_scope_active; then
    command python3 "$@"
    return $?
  fi
  # Only pass through nix-managed Python 3 from this repo (pkgs.python3).
  # whence -p resolves the actual binary path, unlike command -v which can
  # return the shell function name when a function shadows the command.
  local _nucleus_python3_real
  _nucleus_python3_real="$(realpath "$(whence -p python3 2>/dev/null)" 2>/dev/null)" || _nucleus_python3_real=""
  if [[ "$_nucleus_python3_real" == /nix/store/* ]]; then
    command python3 "$@"
    return $?
  fi
  # Fall back to python() for final resolution (scoped/ban).
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

# Intercept npm/npx/node/corepack invocations.
# These tools are NOT installed by this repository. The sole JS runtime
# and package manager is bun.  Users who separately installed Node.js
# should use bun equivalents instead.
# No DIRENV_DIR pass-through: no devShell in this repo provides these tools.
npm() {
  cat >&2 << 'EOF'
shell: system-wide npm is not used in this environment.
         Use bun equivalents instead:
         - bun install     (install packages)
         - bun add <pkg>   (add a dependency)
         - bun x <cmd>     (run one-shot package commands, replaces npx)
         - bun run         (run package.json scripts)
         Shell shortcuts -ni/-nr/-nx also work.
EOF
  return 1
}

npx() {
  cat >&2 << 'EOF'
shell: system-wide npx is not used in this environment.
         Use bun x <cmd> for one-shot package execution instead.
EOF
  return 1
}

node() {
  cat >&2 << 'EOF'
shell: system-wide Node.js is not used in this environment.
         Use bun as the JavaScript runtime instead:
         - bun <script>   (run a script)
         - bun run        (run package.json scripts)
EOF
  return 1
}

corepack() {
  cat >&2 << 'EOF'
shell: corepack is not used in this environment.
         Use bun for package management instead.
EOF
  return 1
}

__MACOS_ICLOUD_HOOKS__
