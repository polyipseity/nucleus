#!/usr/bin/env bash
# ClawHub fetched skill convergence (install + stale cleanup).
# WHY: the repo root is resolved via derive_repo_root() so the manifest is read
# from the live checkout, never a read-only Nix store snapshot.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/symlink-hardening.sh
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_scs_jq_bin="$1"
_scs_path_prepend="$2"
_scs_path_append="$3"
_scs_manifest_rel="$4"
_scs_clawhub_bin="$5"

_scs_repo_root="$(derive_repo_root)" || die -l clawhub "cannot resolve repo root for the fetched skill manifest"

_scs_do_sync=true

# Add the managed bin directories (managed-paths.nix pathComponents) so the
# ClawHub binary installed by install-bun-packages is on PATH here.
PATH="${_scs_path_prepend}$PATH${_scs_path_append}"
export PATH

# The manifest lists the fetched slugs; a slug absent from it is stale.
_scs_manifest="$_scs_repo_root/$_scs_manifest_rel"
if [ ! -f "$_scs_manifest" ]; then
  say -l clawhub "manifest not found at $_scs_manifest; skipping fetched skill sync"
  _scs_do_sync=false
fi

_scs_slugs_file="$(mktemp)"
if [ "$_scs_do_sync" = true ]; then
  "$_scs_jq_bin" -r '.skills[]?' "$_scs_manifest" >"$_scs_slugs_file"

  if [ ! -s "$_scs_slugs_file" ]; then
    say -l clawhub "no fetched skills in manifest; skipping"
    _scs_do_sync=false
  fi
fi

_scs_skills_dir="$HOME/.agents/skills"

# WHY: the skills activation creates this during home-manager switch; guard
# against running before that activation has run.
if [ ! -d "$_scs_skills_dir" ]; then
  mkdir -p "$_scs_skills_dir"
fi

# install-bun-packages owns installing the ClawHub CLI; this step never does.
if [ "$_scs_do_sync" = true ] && ! command -v clawhub >/dev/null 2>&1; then
  warn -l clawhub "clawhub not found in PATH; install-bun-packages must complete before fetched skill sync; skipping"
  _scs_do_sync=false
fi

if [ "$_scs_do_sync" = true ]; then
  say -l clawhub "running fetched skill sync..."

  # --workdir "$HOME/.agents" installs to $HOME/.agents/skills/<slug>/
  #   (the default --dir is "skills"); --no-input keeps it non-interactive
  while IFS= read -r _scs_slug; do
    [ -z "$_scs_slug" ] && continue
    _scs_skill_path="$_scs_skills_dir/$_scs_slug"
    if [ -L "$_scs_skill_path" ]; then
      # A committed-skill (bundled) symlink exists with the same slug.
      # Skip to avoid overwriting the managed symlink; the slug must be
      # removed from clawhub-skills.json or the committed skill removed.
      warn -l clawhub "skipping '$_scs_slug' — a committed-skill symlink exists at $_scs_skill_path"
      continue
    fi
    # Unlock an existing fetched skill directory before updating so
    # ClawHub can overwrite files locked a-w on a previous install.
    if [ -d "$_scs_skill_path" ]; then
      chmod -R u+w "$_scs_skill_path"
    fi
    say -l clawhub "installing/updating fetched skill '$_scs_slug'..."
    # WHY: a non-zero exit from ClawHub is non-fatal, because the system apply
    # already succeeded and skill sync is additive.
    if "$_scs_clawhub_bin" install --workdir "$HOME/.agents" --no-input "$_scs_slug"; then
      # Lock installed content so files cannot be modified outside a
      # managed apply run.  The unlock above re-opens write access before
      # the next update.
      if [ -d "$_scs_skill_path" ]; then
        chmod -R a-w "$_scs_skill_path"
      fi
    else
      die -l clawhub "clawhub install failed for '$_scs_slug' (system apply succeeded)"
    fi
  done <"$_scs_slugs_file"

  # Stale cleanup: remove real directories in ~/.agents/skills/ that have
  # a .clawhub/origin.json marker (written by ClawHub at install time,
  # identifying fetched downloads) but whose slug is no longer in manifest.
  # Directories without this marker (bundled symlinks or user content) are
  # never touched.
  _scs_stale_list="$(mktemp)"
  find "$_scs_skills_dir" -mindepth 1 -maxdepth 1 -type d >"$_scs_stale_list"
  while IFS= read -r _scs_candidate; do
    [ -z "$_scs_candidate" ] && continue
    _scs_name="$(basename "$_scs_candidate")"
    [ ! -f "$_scs_candidate/.clawhub/origin.json" ] && continue
    if ! grep -qxF "$_scs_name" "$_scs_slugs_file"; then
      say -l clawhub "removing stale fetched skill '$_scs_name' (removed from manifest)"
      # Unlock before removal: fetched skill trees are locked a-w after
      # install, so rm -rf needs write access restored first.
      chmod -R u+w "$_scs_candidate"
      rm -rf "$_scs_candidate"
    fi
  done <"$_scs_stale_list"
  rm -f "$_scs_stale_list"
  say -l clawhub "fetched skill sync complete"
fi

rm -f "$_scs_slugs_file"
