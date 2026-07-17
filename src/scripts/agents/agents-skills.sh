# shellcheck shell=sh
# Creates ~/.agents/skills/ as a real directory then populates it with
# per-skill symlinks for every skill subdirectory committed to
# src/modules/configs/agents/skills/.
# Requires: REPO_ROOT, AGENTS_SKILLS_RELATIVE_PATH env vars.
# Agent helpers (_nucleus_protect_symlink, _nucleus_unprotect_symlink,
# _nucleus_resolve_repo_root) must be sourced before this script.

_ask_repo_root="$(_nucleus_resolve_repo_root "agents-skills" "$REPO_ROOT")"

_ask_skills_source="$_ask_repo_root/$AGENTS_SKILLS_RELATIVE_PATH"
if [ ! -d "$_ask_skills_source" ]; then
  echo "agents-skills: skills source dir not found: $_ask_skills_source" >&2
  exit 1
fi

_ask_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists as a real directory so fetched ClawHub
# downloads can be written here without entering the tracked repo tree.
if [ ! -d "$_ask_skills_dir" ]; then
  mkdir -p "$_ask_skills_dir"
  echo "agents-skills: created $HOME/.agents/skills"
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
        _nucleus_unprotect_symlink "agents-skills" "$_ask_candidate"
        rm "$_ask_candidate"
        echo "agents-skills: removed stale skill link for $_ask_cname (source removed)"
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
    _nucleus_unprotect_symlink "agents-skills" "$_ask_link"
    rm "$_ask_link"
    ln -s "$_ask_skill_dir" "$_ask_link"
    _nucleus_protect_symlink "agents-skills" "$_ask_link"
    echo "agents-skills: updated $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
  elif [ -d "$_ask_link" ]; then
    # Real directory in place of a committed skill — could be a fetched
    # download with the same name, or user data.  Fail fast to prevent
    # silent overwrites; the operator must resolve the conflict manually.
    echo "agents-skills: $HOME/.agents/skills/$_ask_skill_name is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." >&2
    exit 1
  else
    ln -s "$_ask_skill_dir" "$_ask_link"
    _nucleus_protect_symlink "agents-skills" "$_ask_link"
    echo "agents-skills: linked $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
  fi
done
