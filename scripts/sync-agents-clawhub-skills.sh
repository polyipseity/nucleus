#!/usr/bin/env sh
# scripts/sync-agents-clawhub-skills.sh — Converge System 2 skills with the manifest.
#
# Downloads or updates skills listed in src/modules/configs/agents/clawhub-skills.json
# via the clawhub CLI into ~/.agents/skills/ (each as a real directory, not a
# committed symlink).  Removes real directories marked as System 2 downloads
# (.clawhub/origin.json present) whose slug is no longer in the manifest.
#
# System 2 skills are those whose license is not AGPL-compatible and therefore
# cannot be committed to this repository.  System 1 (committed, AGPL-compatible)
# skills are managed by the agentsSkills activation (agents.nix / Sync-AgentsSkills).
#
# Commands: none (clawhub CLI is checked/installed if absent)
# Arguments:
#   $1 — absolute path to the nucleus repository checkout root
#
# Environment variables: none (repo root passed as $1)
#
# Exit conditions:
#   0 — manifest absent or empty (nothing to do)
#   0 — all skills converged successfully (new installs may have been performed)
#   1 — critical error: repo root argument missing, python3 unavailable, or
#       manifest unreadable.  Individual skill install failures are non-fatal
#       and produce a warning rather than exiting non-zero; the system apply
#       succeeded and skill sync is best-effort.
set -eu

_repo_root="${1:-}"
if [ -z "$_repo_root" ]; then
  printf '%s\n' "sync-agents-clawhub-skills: usage: $0 <repo-root>" >&2
  exit 1
fi

# Path to the declarative System 2 skill manifest.  Slugs listed here are
# downloaded by clawhub; slugs absent from the manifest are cleaned up from
# ~/.agents/skills/ when their .clawhub/origin.json marker is present.
_manifest="$_repo_root/src/modules/configs/agents/clawhub-skills.json"
if [ ! -f "$_manifest" ]; then
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: manifest not found at $_manifest; skipping"
  exit 0
fi

# Parse skill slugs from the manifest using python3.  jq is not added to
# runtimeInputs solely for this purpose; python3 is available on both macOS
# and NixOS without additional dependencies.
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: python3 not found in PATH; cannot parse manifest" >&2
  exit 1
fi

_slugs_file="$(mktemp)"
# Args: $1 = manifest path.  Outputs one slug per line.
python3 - "$_manifest" > "$_slugs_file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for slug in data.get("skills", []):
    print(slug)
PYEOF

if [ ! -s "$_slugs_file" ]; then
  rm -f "$_slugs_file"
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: no System 2 skills in manifest; skipping"
  exit 0
fi

_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists.  The agentsSkills activation creates it
# during home-manager switch; this guards against running the script directly
# before activation has run.
if [ ! -d "$_skills_dir" ]; then
  mkdir -p "$_skills_dir"
fi

# Ensure the clawhub CLI is available.  clawhub is not in nixpkgs; bun
# (installed via nixpkgs on POSIX hosts) is used as the install vehicle.
# `command -v clawhub` is a probe — a non-zero exit is expected and benign
# when the tool is absent; the result drives the conditional install.
if ! command -v clawhub >/dev/null 2>&1; then
  if ! command -v bun >/dev/null 2>&1; then
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: bun not found in PATH; cannot install clawhub; skipping System 2 skill sync" >&2
    rm -f "$_slugs_file"
    exit 0
  fi
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: clawhub not found; installing via bun..."
  if ! bun install -g clawhub; then
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: bun install -g clawhub failed; skipping System 2 skill sync" >&2
    rm -f "$_slugs_file"
    exit 0
  fi
  # Prepend ~/.bun/bin so the newly installed clawhub binary is discoverable
  # in the current session without spawning a new shell.
  if [ -d "$HOME/.bun/bin" ]; then
    PATH="$HOME/.bun/bin:$PATH"
    export PATH
  fi
fi

# Install or update each skill from the manifest.
#   --workdir "$HOME/.agents"  installs to $HOME/.agents/skills/<slug>/
#                              (default --dir value is "skills")
#   --no-input                 disables interactive prompts for apply safety
while IFS= read -r _slug; do
  [ -z "$_slug" ] && continue
  _skill_path="$_skills_dir/$_slug"
  if [ -L "$_skill_path" ]; then
    # A committed-skill (System 1) symlink exists with the same slug.  Skip to
    # avoid overwriting the managed symlink; the slug must be removed from the
    # manifest or the committed skill must be removed first.
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: skipping '$_slug' — a committed-skill symlink exists at $_skill_path; remove it from clawhub-skills.json or from src/modules/configs/agents/skills/" >&2
    continue
  fi
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: installing/updating System 2 skill '$_slug'..."
  # Non-zero exit from clawhub is non-fatal: the system apply already succeeded;
  # skill sync is additive.  A warning is printed and the loop continues.
  if ! clawhub install --workdir "$HOME/.agents" --no-input "$_slug"; then
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: clawhub install failed for '$_slug' (system apply succeeded)" >&2
  fi
done < "$_slugs_file"

# Stale cleanup: remove real directories in ~/.agents/skills/ that have a
# .clawhub/origin.json marker (written by clawhub at install time, identifying
# them as System 2 downloads) but whose slug is no longer in the manifest.
# Directories without the marker (System 1 committed-skill symlinks or user
# content) are never touched.
_stale_list="$(mktemp)"
find "$_skills_dir" -mindepth 1 -maxdepth 1 -type d > "$_stale_list"
while IFS= read -r _candidate; do
  [ -z "$_candidate" ] && continue
  _cname="$(basename "$_candidate")"
  # Presence of .clawhub/origin.json is the reliable marker for a System 2
  # clawhub download; do not remove directories that lack it.
  [ ! -f "$_candidate/.clawhub/origin.json" ] && continue
  if ! grep -qxF "$_cname" "$_slugs_file"; then
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: removing stale System 2 skill '$_cname' (removed from manifest)"
    rm -rf "$_candidate"
  fi
done < "$_stale_list"
rm -f "$_stale_list" "$_slugs_file"

printf '%s\n' "nucleus: sync-agents-clawhub-skills: System 2 skill sync complete"
