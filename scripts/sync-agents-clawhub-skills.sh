#!/usr/bin/env sh
# scripts/sync-agents-clawhub-skills.sh — Converge fetched skills with the manifest.
#
# Downloads or updates skills listed in src/modules/configs/agents/clawhub-skills.json
# via the clawhub CLI into ~/.agents/skills/ (each as a real directory, not a
# committed symlink).  Removes real directories marked as fetched downloads
# (.clawhub/origin.json present) whose slug is no longer in the manifest.
#
# Fetched skills are those whose license is not AGPL-compatible and therefore
# cannot be committed to this repository.  Bundled (committed, AGPL-compatible)
# skills are managed by the agentsSkills activation (agents.nix / Sync-AgentsSkills).
#
# Commands: none (clawhub CLI must be pre-installed by the installBunPackages
#   Home Manager activation before this script is called)
# Arguments:
#   $1 — absolute path to the nucleus repository checkout root
#
# Environment variables: none (repo root passed as $1)
#
# Exit conditions:
#   0 — manifest absent or empty (nothing to do)
#   0 — all skills converged successfully (new installs may have been performed)
#   1 — critical error: repo root argument missing, jq unavailable, or
#       manifest unreadable.  Individual skill install failures are non-fatal
#       and produce a warning rather than exiting non-zero; the system apply
#       succeeded and skill sync is best-effort.
set -eu

_repo_root="${1:-}"
if [ -z "$_repo_root" ]; then
  printf '%s\n' "sync-agents-clawhub-skills: usage: $0 <repo-root>" >&2
  exit 1
fi

# Path to the declarative fetched skill manifest.  Slugs listed here are
# downloaded by clawhub; slugs absent from the manifest are cleaned up from
# ~/.agents/skills/ when their .clawhub/origin.json marker is present.
_manifest="$_repo_root/src/modules/configs/agents/clawhub-skills.json"
if [ ! -f "$_manifest" ]; then
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: manifest not found at $_manifest; skipping"
  exit 0
fi

# Parse skill slugs from the manifest using jq.  jq is available via
# home.packages in core.nix on all POSIX hosts.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: jq not found in PATH; cannot parse manifest" >&2
  exit 1
fi

_slugs_file="$(mktemp)"
jq -r '.skills[]?' "$_manifest" > "$_slugs_file"

if [ ! -s "$_slugs_file" ]; then
  rm -f "$_slugs_file"
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: no fetched skills in manifest; skipping"
  exit 0
fi

_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists.  The agentsSkills activation creates it
# during home-manager switch; this guards against running the script directly
# before activation has run.
if [ ! -d "$_skills_dir" ]; then
  mkdir -p "$_skills_dir"
fi

# Prepend ~/.bun/bin so the clawhub binary installed by installBunPackages is
# discoverable in the current session.  installBunPackages places bun-managed
# binaries at this path; the prepend is safe even when the directory is absent.
if [ -d "$HOME/.bun/bin" ]; then
  PATH="$HOME/.bun/bin:$PATH"
  export PATH
fi

# Probe for the clawhub CLI.  clawhub must be pre-installed by the
# installBunPackages Home Manager activation before this script is called;
# this script never installs clawhub itself.  A non-zero exit from
# command -v is expected and benign when the binary is absent; the result
# drives the conditional skip below.
if ! command -v clawhub >/dev/null 2>&1; then
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: clawhub not found in PATH; the installBunPackages activation must complete before running this script; skipping fetched skill sync" >&2
  rm -f "$_slugs_file"
  exit 0
fi

# Install or update each skill from the manifest.
#   --workdir "$HOME/.agents"  installs to $HOME/.agents/skills/<slug>/
#                              (default --dir value is "skills")
#   --no-input                 disables interactive prompts for apply safety
while IFS= read -r _slug; do
  [ -z "$_slug" ] && continue
  _skill_path="$_skills_dir/$_slug"
  if [ -L "$_skill_path" ]; then
    # A committed-skill (bundled) symlink exists with the same slug.  Skip to
    # avoid overwriting the managed symlink; the slug must be removed from the
    # manifest or the committed skill must be removed first.
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: skipping '$_slug' — a committed-skill symlink exists at $_skill_path; remove it from clawhub-skills.json or from src/modules/configs/agents/skills/" >&2
    continue
  fi
  # Unlock an existing fetched skill directory before updating so clawhub can
  # overwrite files that were locked a-w on a previous install.
  if [ -d "$_skill_path" ]; then
    chmod -R u+w "$_skill_path"
  fi
  printf '%s\n' "nucleus: sync-agents-clawhub-skills: installing/updating fetched skill '$_slug'..."
  # Non-zero exit from clawhub is non-fatal: the system apply already succeeded;
  # skill sync is additive.  A warning is printed and the loop continues.
  if clawhub install --workdir "$HOME/.agents" --no-input "$_slug"; then
    # Lock installed content so files cannot be modified outside a managed apply
    # run.  The unlock above re-opens write access before the next update.
    if [ -d "$_skill_path" ]; then
      chmod -R a-w "$_skill_path"
    fi
  else
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: clawhub install failed for '$_slug' (system apply succeeded)" >&2
  fi
done < "$_slugs_file"

# Stale cleanup: remove real directories in ~/.agents/skills/ that have a
# .clawhub/origin.json marker (written by clawhub at install time, identifying
# them as fetched downloads) but whose slug is no longer in the manifest.
# Directories without the marker (bundled committed-skill symlinks or user
# content) are never touched.
_stale_list="$(mktemp)"
find "$_skills_dir" -mindepth 1 -maxdepth 1 -type d > "$_stale_list"
while IFS= read -r _candidate; do
  [ -z "$_candidate" ] && continue
  _cname="$(basename "$_candidate")"
  # Presence of .clawhub/origin.json is the reliable marker for a fetched
  # clawhub download; do not remove directories that lack it.
  [ ! -f "$_candidate/.clawhub/origin.json" ] && continue
  if ! grep -qxF "$_cname" "$_slugs_file"; then
    printf '%s\n' "nucleus: sync-agents-clawhub-skills: removing stale fetched skill '$_cname' (removed from manifest)"
    # Unlock before removal: the skill was locked a-w after install; rm -rf
    # needs user-write permission on subdirectories to remove their contents.
    chmod -R u+w "$_candidate"
    rm -rf "$_candidate"
  fi
done < "$_stale_list"
rm -f "$_stale_list" "$_slugs_file"

printf '%s\n' "nucleus: sync-agents-clawhub-skills: fetched skill sync complete"
