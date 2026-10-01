# Zsh initialization for nucleus-managed hosts. History exclusion, completion
# directory, agent-session detection, dev tool interception, srt agent wrapping.
# Embedded by src/modules/shell.nix into initContent.

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
