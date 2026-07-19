# ClawHub fetched skill convergence (install + stale cleanup).
# Consumes tool paths and repo root token at activation time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_scs_jq_bin='__JQ_BIN__'

_scs_do_sync=true

# Add managed bin directories (managed-paths.nix pathComponents) to PATH
# so the ClawHub binary installed by installBunPackages is on PATH for
# this activation step.
PATH="__PATH_PREPEND_GUARD__$PATH__PATH_APPEND_GUARD__"
export PATH

# Resolve the repo root (same mechanism as symlink and skills).
_scs_repo_root="$(_nucleus_resolve_repo_root "clawhub" "__REPO_ROOT__")"

# Path to the declarative fetched skill manifest.  Slugs listed here are
# downloaded by ClawHub; slugs absent from the manifest are cleaned up
# from ~/.agents/skills/ when their .clawhub/origin.json marker is
# present.
_scs_manifest="$_scs_repo_root/__CLAWHUB_MANIFEST_RELATIVE_PATH__"
if [ ! -f "$_scs_manifest" ]; then
  echo "clawhub: manifest not found at $_scs_manifest; skipping fetched skill sync"
  _scs_do_sync=false
fi

_scs_slugs_file="$(mktemp)"
if [ "$_scs_do_sync" = true ]; then
  "$_scs_jq_bin" -r '.skills[]?' "$_scs_manifest" > "$_scs_slugs_file"

  if [ ! -s "$_scs_slugs_file" ]; then
    echo "clawhub: no fetched skills in manifest; skipping"
    _scs_do_sync=false
  fi
fi

_scs_skills_dir="$HOME/.agents/skills"

# Ensure ~/.agents/skills/ exists.  The skills activation creates
# it during home-manager switch; this guards against running before that
# activation has run.
if [ ! -d "$_scs_skills_dir" ]; then
  mkdir -p "$_scs_skills_dir"
fi

# Probe for the ClawHub CLI.  ClawHub must be pre-installed by the
# installBunPackages activation before this step is called; this step
# never installs ClawHub itself.
if [ "$_scs_do_sync" = true ] && ! command -v clawhub >/dev/null 2>&1; then
  echo "clawhub: clawhub not found in PATH; installBunPackages must complete before fetched skill sync; skipping" >&2
  _scs_do_sync=false
fi

if [ "$_scs_do_sync" = true ]; then
  echo "clawhub: running fetched skill sync..."

  # Install or update each skill from the manifest.
  #   --workdir "$HOME/.agents" installs to $HOME/.agents/skills/<slug>/
  #                            (default --dir value is "skills")
  #   --no-input               disables interactive prompts for apply safety
  while IFS= read -r _scs_slug; do
    [ -z "$_scs_slug" ] && continue
    _scs_skill_path="$_scs_skills_dir/$_scs_slug"
    if [ -L "$_scs_skill_path" ]; then
      # A committed-skill (bundled) symlink exists with the same slug.
      # Skip to avoid overwriting the managed symlink; the slug must be
      # removed from clawhub-skills.json or the committed skill removed.
      echo "clawhub: skipping '$_scs_slug' — a committed-skill symlink exists at $_scs_skill_path" >&2
      continue
    fi
    # Unlock an existing fetched skill directory before updating so
    # ClawHub can overwrite files locked a-w on a previous install.
    if [ -d "$_scs_skill_path" ]; then
      chmod -R u+w "$_scs_skill_path"
    fi
    echo "clawhub: installing/updating fetched skill '$_scs_slug'..."
    # Best-effort: non-zero exit from ClawHub is non-fatal because the
    # system apply already succeeded and skill sync is additive.
    if clawhub install --workdir "$HOME/.agents" --no-input "$_scs_slug"; then
      # Lock installed content so files cannot be modified outside a
      # managed apply run.  The unlock above re-opens write access before
      # the next update.
      if [ -d "$_scs_skill_path" ]; then
        chmod -R a-w "$_scs_skill_path"
      fi
    else
      echo "clawhub: clawhub install failed for '$_scs_slug' (system apply succeeded)" >&2
    fi
  done < "$_scs_slugs_file"

  # Stale cleanup: remove real directories in ~/.agents/skills/ that have
  # a .clawhub/origin.json marker (written by ClawHub at install time,
  # identifying fetched downloads) but whose slug is no longer in manifest.
  # Directories without this marker (bundled symlinks or user content) are
  # never touched.
  _scs_stale_list="$(mktemp)"
  find "$_scs_skills_dir" -mindepth 1 -maxdepth 1 -type d > "$_scs_stale_list"
  while IFS= read -r _scs_candidate; do
    [ -z "$_scs_candidate" ] && continue
    _scs_name="$(basename "$_scs_candidate")"
    [ ! -f "$_scs_candidate/.clawhub/origin.json" ] && continue
    if ! grep -qxF "$_scs_name" "$_scs_slugs_file"; then
      echo "clawhub: removing stale fetched skill '$_scs_name' (removed from manifest)"
      # Unlock before removal: fetched skill trees are locked a-w after
      # install, so rm -rf needs write access restored first.
      chmod -R u+w "$_scs_candidate"
      rm -rf "$_scs_candidate"
    fi
  done < "$_scs_stale_list"
  rm -f "$_scs_stale_list"
  echo "clawhub: fetched skill sync complete"
fi

rm -f "$_scs_slugs_file"
