#!/usr/bin/env bash
# Strip stale managed entries from PATH, then prepend + append managed dirs.
# All values passed as CLI args:
#   $1 = prepend PATH fragment  (colon-separated, may be empty)
#   $2 = append PATH fragment  (colon-separated)
#   $3 = managed dedup set     (colon-separated absolute paths)
#   $4 = env var commands      (multi-line shell code for launchctl setenv)
set -eu

__nucleus_prepend="${1:?}"
__nucleus_append="${2:?}"
__nucleus_managed_set="${3:?}"
__all_vars="${4:-}"

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
