# Strip stale managed entries from launchctl PATH, then prepend + append
# managed dirs for the GUI launchd domain.
#
# Environment variables set by Nix wrapper:
#   __nucleus_prepend, __nucleus_append, __nucleus_managed_set

CURRENT_PATH="$(/bin/launchctl getenv PATH 2>/dev/null || true)"  # undoc-supp: launchctl may not be available (early boot, non-GUI session); fall back to $PATH
if [ -z "$CURRENT_PATH" ]; then
  CURRENT_PATH="$PATH"
fi

__nucleus_cleaned=""
old_IFS="$IFS"
IFS=:
for __component in $CURRENT_PATH; do
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
