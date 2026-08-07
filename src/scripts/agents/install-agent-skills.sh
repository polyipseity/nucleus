#!/usr/bin/env bash
# Creates ~/.agents/skills/ as a real directory then populates it with
# per-skill symlinks for every skill subdirectory in the resolved agents overlay.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/symlink-convergence.sh"
. "$SCRIPT_DIR/../lib/resolve-user-config.sh"

_ask_repo_root="$1"
_ask_username="$2"
_ask_agents_dir="$(resolve_user_config_dir "$_ask_username" "agents")"
_ask_skills_source="$_ask_agents_dir/skills"
if [ ! -d "$_ask_skills_source" ]; then
  echo "skills: skills source dir not found: $_ask_skills_source" >&2
  exit 1
fi

_ask_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists as a real directory so fetched ClawHub
# downloads can be written here without entering the tracked repo tree.
if [ ! -d "$_ask_skills_dir" ]; then
  mkdir -p "$_ask_skills_dir"
  echo "skills: created $HOME/.agents/skills"
fi

_nucleus_remove_stale_symlinks \
  "$_ask_skills_dir" "$_ask_skills_source" "skills" ""

_nucleus_converge_symlinks \
  "$_ask_skills_source" "$_ask_skills_dir" "skills" \
  "-type d" "-d" \
  "is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." \
  "" \
  "backup"
