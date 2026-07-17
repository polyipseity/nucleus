# Strip stale managed entries from PATH, then prepend + append managed dirs.
# Environment variables set by Nix wrapper:
#   __nucleus_prepend, __nucleus_append, __nucleus_managed_set

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
