#!/usr/bin/env bash
# Strip stale managed entries from PATH, then prepend + append managed dirs.
set -eu

# Tokens substituted at build time by Nix.
__nucleus_prepend="__NUCLEUS_PREPEND__"
__nucleus_append="__NUCLEUS_APPEND__"
__nucleus_managed_set="__NUCLEUS_MANAGED_SET__"

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
__MACOS_ALL_VARS__
