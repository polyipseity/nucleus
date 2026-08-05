#!/usr/bin/env bash
# Strip stale managed entries from PATH, then prepend + append managed dirs.
# All values can be passed via env vars or CLI args:
#   GUI_ENV_PREPEND_PATH  / $1 = prepend PATH fragment  (colon-separated, may be empty)
#   GUI_ENV_APPEND_PATH   / $2 = append PATH fragment  (colon-separated)
#   GUI_ENV_DEDUP_SET_HOME / $3 = managed dedup set     (colon-separated absolute paths)
#   GUI_ENV_MACOS_ALL_VARS / $4 = env var commands      (multi-line shell code for launchctl setenv)
set -eu

# `:-` not `:?`: empty prepend/append are legitimate (managedPaths.prepend is
# currently empty); `:?` killed the whole agent at login with exit 1.
__nucleus_prepend="${GUI_ENV_PREPEND_PATH:-${1:-}}"
__nucleus_append="${GUI_ENV_APPEND_PATH:-${2:-}}"
__nucleus_managed_set="${GUI_ENV_DEDUP_SET_HOME:-${3:-}}"
__all_vars="${GUI_ENV_MACOS_ALL_VARS:-${4:-}}"

__nucleus_cleaned=""
old_IFS="$IFS"
IFS=:
for __component in $PATH; do
  case ":${__nucleus_managed_set}:" in
    *":${__component}:"*) ;;
    *) __nucleus_cleaned="${__nucleus_cleaned}:${__component}" ;;
  esac
done
IFS="$old_IFS"

if [ -n "$__nucleus_cleaned" ]; then
  /bin/launchctl setenv PATH "${__nucleus_prepend}:${__nucleus_cleaned}:${__nucleus_append}"
else
  /bin/launchctl setenv PATH "${__nucleus_prepend}:${__nucleus_append}"
fi

# ── All other GUI env vars (user and non-user) ──
eval "$__all_vars"
