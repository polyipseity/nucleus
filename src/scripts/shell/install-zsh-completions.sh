#!/usr/bin/env bash
# Idempotently generate zsh completion files for CLI tools whose Nix packages
# do not auto-bundle them into fpath.
#
# Variables below are substituted via Nix replaceStrings at build time.
#
# Each token expands to a Nix store path (e.g. "${pkgs.bat}/bin/bat").

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

  echo "zsh-completions: generating ${_comp_file##*/}"
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
  __BAT_BIN__ \
  "$_zsh_comp_dir/_bat" \
  "'__BAT_BIN__' --completion zsh"

_generate_if_stale \
  __BUN_BIN__ \
  "$_zsh_comp_dir/_bun" \
  "'__BUN_BIN__' completions"

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
  __FD_BIN__ \
  "$_zsh_comp_dir/_fd" \
  "'__FD_BIN__' --gen-completions zsh"

_generate_if_stale \
  __GH_BIN__ \
  "$_zsh_comp_dir/_gh" \
  "'__GH_BIN__' completion -s zsh"

_generate_if_stale \
  __OPENCODE_BIN__ \
  "$_zsh_comp_dir/_opencode" \
  "'__OPENCODE_BIN__' completion zsh"

# prek skipped: no completion subcommand exists in current version
# (confirmed 2026-07-01). "prek completion zsh" is interpreted as hook
# selectors, not a completion command.
#_generate_if_stale \
#  "${pkgs.prek}/bin/prek" \
#  "$_zsh_comp_dir/_prek" \
#  "'${pkgs.prek}/bin/prek' completion zsh"

_generate_if_stale \
  __RUFF_BIN__ \
  "$_zsh_comp_dir/_ruff" \
  "'__RUFF_BIN__' generate-shell-completion zsh"

_generate_if_stale \
  __RUSTUP_BIN__ \
  "$_zsh_comp_dir/_rustup" \
  "'__RUSTUP_BIN__' completions zsh"

_generate_if_stale \
  __TYPST_BIN__ \
  "$_zsh_comp_dir/_typst" \
  "'__TYPST_BIN__' completions zsh"

_generate_if_stale \
  __UV_BIN__ \
  "$_zsh_comp_dir/_uv" \
  "'__UV_BIN__' generate-shell-completion zsh"

# -----------------------------------------------------------------------
# Nucleus-command completions: static zsh completion files shipped with
# the repository. Copied directly (no generation needed).
# -----------------------------------------------------------------------
for _zsh_nuc_f in "__ZSH_COMPLETIONS_SRC__"/_nucleus-* "__ZSH_COMPLETIONS_SRC__"/_nucleus; do
  [ -f "$_zsh_nuc_f" ] || continue
  cp -f "$_zsh_nuc_f" "$_zsh_comp_dir/"
done

echo "zsh-completions: done"
