#!/usr/bin/env bash
# Idempotently generate zsh completion files for CLI tools whose Nix packages
# do not auto-bundle them into fpath.
# CLI args: bat_bin bun_bin fd_bin gh_bin opencode_bin ruff_bin rustup_bin typst_bin uv_bin zsh_completions_src
set -euo pipefail


_izc_bat_bin="$1"
_izc_bun_bin="$2"
_izc_fd_bin="$3"
_izc_gh_bin="$4"
_izc_opencode_bin="$5"
_izc_ruff_bin="$6"
_izc_rustup_bin="$7"
_izc_typst_bin="$8"
_izc_uv_bin="$9"
_izc_zsh_completions_src="${10}"

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
  "$_izc_bat_bin" \
  "$_zsh_comp_dir/_bat" \
  "'$_izc_bat_bin' --completion zsh"

_generate_if_stale \
  "$_izc_bun_bin" \
  "$_zsh_comp_dir/_bun" \
  "'$_izc_bun_bin' completions"

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
  "$_izc_fd_bin" \
  "$_zsh_comp_dir/_fd" \
  "'$_izc_fd_bin' --gen-completions zsh"

_generate_if_stale \
  "$_izc_gh_bin" \
  "$_zsh_comp_dir/_gh" \
  "'$_izc_gh_bin' completion -s zsh"

_generate_if_stale \
  "$_izc_opencode_bin" \
  "$_zsh_comp_dir/_opencode" \
  "'$_izc_opencode_bin' completion zsh"

# prek skipped: no completion subcommand exists in current version
# (confirmed 2026-07-01). "prek completion zsh" is interpreted as hook
# selectors, not a completion command.
#_generate_if_stale \
#  "${pkgs.prek}/bin/prek" \
#  "$_zsh_comp_dir/_prek" \
#  "'${pkgs.prek}/bin/prek' completion zsh"

_generate_if_stale \
  "$_izc_ruff_bin" \
  "$_zsh_comp_dir/_ruff" \
  "'$_izc_ruff_bin' generate-shell-completion zsh"

_generate_if_stale \
  "$_izc_rustup_bin" \
  "$_zsh_comp_dir/_rustup" \
  "'$_izc_rustup_bin' completions zsh"

_generate_if_stale \
  "$_izc_typst_bin" \
  "$_zsh_comp_dir/_typst" \
  "'$_izc_typst_bin' completions zsh"

_generate_if_stale \
  "$_izc_uv_bin" \
  "$_zsh_comp_dir/_uv" \
  "'$_izc_uv_bin' generate-shell-completion zsh"

# -----------------------------------------------------------------------
# Nucleus-command completions: static zsh completion files shipped with
# the repository. Copied directly (no generation needed).
# -----------------------------------------------------------------------
for _zsh_nuc_f in "$_izc_zsh_completions_src"/_nucleus-* "$_izc_zsh_completions_src"/_nucleus; do
  [ -f "$_zsh_nuc_f" ] || continue
  cp -f "$_zsh_nuc_f" "$_zsh_comp_dir/"
done

echo "zsh-completions: done"

echo "zsh-completions: done"
