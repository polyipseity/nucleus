# shellcheck shell=sh
# Creates ~/.agents/skills/ as a real directory then populates it with
# per-skill symlinks for every skill subdirectory committed to
# src/modules/configs/agents/skills/.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_ask_repo_root="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
_ask_skills_source="$_ask_repo_root/src/modules/configs/agents/skills"
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

# Remove stale per-skill symlinks: skill dirs that once existed in the
# source but have since been removed from the repo.
find "$_ask_skills_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _ask_candidate; do
  _ask_cname="$(basename "$_ask_candidate")"
  _ask_ctarget="$(readlink "$_ask_candidate")"
  case "$_ask_ctarget" in
    "$_ask_skills_source"/*)
      # Managed per-skill symlink: remove if its source no longer exists.
      if [ ! -e "$_ask_ctarget" ] && [ ! -L "$_ask_ctarget" ]; then
        _nucleus_unprotect_symlink "skills" "$_ask_candidate"
        rm "$_ask_candidate"
        echo "skills: removed stale skill link for $_ask_cname (source removed)"
      fi
      ;;
  esac
done

# Create or update per-skill symlinks for every subdirectory committed to
# src/modules/configs/agents/skills/.  Non-directory entries (.gitkeep etc.)
# are skipped; only skill directories are linked.
find "$_ask_skills_source" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r _ask_skill_dir; do
  _ask_skill_name="$(basename "$_ask_skill_dir")"
  _ask_link="$_ask_skills_dir/$_ask_skill_name"
  if [ -L "$_ask_link" ]; then
    if [ "$(readlink "$_ask_link")" = "$_ask_skill_dir" ]; then
      continue  # Correct symlink — no-op.
    fi
    # Wrong target: replace symlink.
    _nucleus_unprotect_symlink "skills" "$_ask_link"
    rm "$_ask_link"
    ln -s "$_ask_skill_dir" "$_ask_link"
    _nucleus_protect_symlink "skills" "$_ask_link"
    echo "skills: updated $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
  elif [ -d "$_ask_link" ]; then
    # Real directory in place of a committed skill — could be a fetched
    # download with the same name, or user data.  Fail fast to prevent
    # silent overwrites; the operator must resolve the conflict manually.
    echo "skills: $HOME/.agents/skills/$_ask_skill_name is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." >&2
    exit 1
  else
    ln -s "$_ask_skill_dir" "$_ask_link"
    _nucleus_protect_symlink "skills" "$_ask_link"
    echo "skills: linked $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
  fi
done
