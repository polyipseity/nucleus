#!/usr/bin/env bash
# Creates ~/.agents/skills/ as a real directory then populates it with
# per-skill symlinks for every skill subdirectory in the resolved agents overlay.
# Optionally symlinks additional skills from extra source directories.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/symlink-convergence.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"

_ask_repo_root="$1"
_ask_username="$2"
_ask_extra_skills_source="${3:-}"
# Skip exporting NUCLEUS_REPO_ROOT when the path is a Nix store snapshot —
# derive_repo_root() will fall back to the system repo-root file silently.
if [ -n "$_ask_repo_root" ] && case "$_ask_repo_root" in /nix/store/*) false ;; *) true ;; esac then
  export NUCLEUS_REPO_ROOT="$_ask_repo_root"
fi
if ! _ask_skills_source="$(resolve_user_config_first_level_entry "$_ask_username" "agents" "skills")"; then
  die -l skills "cannot resolve the agents skills overlay source — repo root unavailable (checked NUCLEUS_REPO_ROOT and the system repo-root file)"
fi
if [ ! -d "$_ask_skills_source" ]; then
  die -l skills "skills source dir not found: $_ask_skills_source"
fi

_ask_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists as a real directory so fetched ClawHub
# downloads can be written here without entering the tracked repo tree.
if [ ! -d "$_ask_skills_dir" ]; then
  mkdir -p "$_ask_skills_dir"
  say -l skills "created $HOME/.agents/skills"
fi

_nucleus_remove_stale_symlinks \
  "$_ask_skills_dir" "$_ask_skills_source" "skills" ""

_nucleus_converge_symlinks \
  "$_ask_skills_source" "$_ask_skills_dir" "skills" \
  "-type d" "-d" \
  "is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." \
  ""

# Symlink additional skills from extra source directory if provided.
# Used for superpowers skills and other externally-fetched skill bundles.
if [ -n "$_ask_extra_skills_source" ] && [ -d "$_ask_extra_skills_source" ]; then
  _nucleus_converge_symlinks \
    "$_ask_extra_skills_source" "$_ask_skills_dir" "skills" \
    "-type d" "-d" \
    "is a real directory — if it is a fetched skill that has been re-committed, remove it and re-run apply." \
    ""
fi
