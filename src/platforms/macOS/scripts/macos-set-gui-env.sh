#!/usr/bin/env bash
# Strip stale managed entries from PATH, then prepend + append managed dirs.
# All values can be passed via env vars or CLI args:
#   GUI_ENV_PREPEND_PATH  / $1 = prepend PATH fragment  (colon-separated, may be empty)
#   GUI_ENV_APPEND_PATH   / $2 = append PATH fragment  (colon-separated)
#   GUI_ENV_DEDUP_SET_HOME / $3 = managed dedup set     (colon-separated absolute paths)
#   GUI_ENV_MACOS_ALL_VARS / $4 = env var commands      (multi-line shell code for launchctl setenv)
#   GUI_ENV_LAUNCHCTL            = launchctl binary      (default /bin/launchctl; override in tests)
set -eu

# `:-` not `:?`: empty prepend/append are legitimate (managedPaths.prepend is
# currently empty); `:?` killed the whole agent at login with exit 1.
__nucleus_prepend="${GUI_ENV_PREPEND_PATH:-${1:-}}"
__nucleus_append="${GUI_ENV_APPEND_PATH:-${2:-}}"
__nucleus_managed_set="${GUI_ENV_DEDUP_SET_HOME:-${3:-}}"
__all_vars="${GUI_ENV_MACOS_ALL_VARS:-${4:-}}"
__nucleus_launchctl="${GUI_ENV_LAUNCHCTL:-/bin/launchctl}"

__nucleus_cleaned=""
old_IFS="$IFS"
IFS=:
for __component in $PATH; do
  case ":${__nucleus_managed_set}:" in
  *":${__component}:"*) ;;
  *)
    __nucleus_cleaned="${__nucleus_cleaned:+${__nucleus_cleaned}:}${__component}"
    ;;
  esac
done
IFS="$old_IFS"

# Compose PATH from non-empty fragments only (prepend may be empty, cleaned
# may be empty when every PATH entry is managed, append may be empty).  A
# guard expression cannot express "join non-empty segments with a single
# colon": when prepend AND cleaned are both empty, the append guard's leading
# colon survives and the PATH starts with an empty entry (= cwd).
__nucleus_path=""
for __nucleus_frag in "$__nucleus_prepend" "$__nucleus_cleaned" "$__nucleus_append"; do
  [ -n "$__nucleus_frag" ] || continue
  if [ -n "$__nucleus_path" ]; then
    __nucleus_path="${__nucleus_path}:${__nucleus_frag}"
  else
    __nucleus_path="$__nucleus_frag"
  fi
done
"$__nucleus_launchctl" setenv PATH "$__nucleus_path"

# ── All other GUI env vars (user and non-user) ──
eval "$__all_vars"

# ── NUCLEUS_REPO_ROOT from system repo-root file ──
# WHY: NUCLEUS_REPO_ROOT was removed from the env catalog to prevent Nix store
# path poisoning, but some scripts still read it directly.  Set it here from
# the authoritative system repo-root file so GUI processes always see the
# correct live checkout path.
__nucleus_repo_root_file="/Library/Application Support/nucleus/repo-root"
if [ -f "$__nucleus_repo_root_file" ] && IFS= read -r __nucleus_repo_root_val <"$__nucleus_repo_root_file" 2>/dev/null; then
  case "$__nucleus_repo_root_val" in
  /*) "$__nucleus_launchctl" setenv NUCLEUS_REPO_ROOT "$__nucleus_repo_root_val" ;;
  esac
fi
