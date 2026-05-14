#!/usr/bin/env sh
# Guides one-time cloud remote setup and converges cloud mount automation.
#
# Operations:
#   1. verify required rclone remotes exist (GoogleDrive, OneDrive)
#   2. if missing, open interactive rclone config once
#   3. run nucleus apply so cloud mount services/units converge immediately
#
# Arguments:
#   --skip-apply  validate/setup remotes only; do not run apply
#
# Exit conditions:
#   0 on success; non-zero when required remotes are still missing after setup.

set -eu

resolve_nucleus_root() {
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  # Stderr suppressed: git failure outside a repository is expected and benign;
  # the exit code is checked via the conditional.
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$_rnr_git_root"
    return 0
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}

collect_missing_remotes() {
  _required="$1"

  # Stderr suppressed: when rclone has no config yet, listremotes may print
  # expected setup hints; we only need the parsed remote names here and branch
  # on the command exit code below.
  if ! _listed="$(rclone listremotes 2>/dev/null)"; then
    return 1
  fi

  _missing=""
  for _remote in $_required; do
    if ! printf '%s\n' "$_listed" | grep -Fxq "${_remote}:"; then
      if [ -z "$_missing" ]; then
        _missing="$_remote"
      else
        _missing="$_missing $_remote"
      fi
    fi
  done

  printf '%s\n' "$_missing"
}

skip_apply=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-apply)
      skip_apply=true
      ;;
    *)
      printf '%s\n' "cloud-setup: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

if ! command -v rclone >/dev/null 2>&1; then
  printf '%s\n' "cloud-setup: rclone not found on PATH. Run apply/bootstrap first, then retry." >&2
  exit 1
fi

required_remotes="GoogleDrive OneDrive"
missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
  printf '%s\n' "cloud-setup: failed to read rclone remotes. Run 'rclone config' manually and retry." >&2
  exit 1
}

if [ -n "$missing_remotes" ]; then
  printf '%s\n' "cloud-setup: missing rclone remotes: $missing_remotes"
  printf '%s\n' "cloud-setup: launching interactive rclone configuration..."
  rclone config

  missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
    printf '%s\n' "cloud-setup: failed to re-read rclone remotes after configuration." >&2
    exit 1
  }
fi

if [ -n "$missing_remotes" ]; then
  printf '%s\n' "cloud-setup: required remotes are still missing: $missing_remotes" >&2
  printf '%s\n' "cloud-setup: rerun this command after completing those remotes in rclone config." >&2
  exit 1
fi

printf '%s\n' "cloud-setup: required remotes are configured."

if [ "$skip_apply" = false ]; then
  repo_root="$(resolve_nucleus_root)"
  printf '%s\n' "cloud-setup: running nucleus apply to converge cloud mount services..."
  nix run "$repo_root/src#apply"
fi

printf '%s\n' "cloud-setup: setup complete"
