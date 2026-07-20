# Propagate NUCLEUS_REPO_ROOT to the GUI launchd domain.
# Set during activation; the gui-env LaunchAgent covers login-time before first activation.
if [ -n "${NUCLEUS_REPO_ROOT:-}" ]; then
  /bin/launchctl setenv NUCLEUS_REPO_ROOT "$NUCLEUS_REPO_ROOT"
fi

# Strip stale managed entries from launchctl PATH, then prepend + append
# managed dirs for the GUI launchd domain.
#
# Variables below are substituted via Nix replaceStrings at build time.

__nucleus_prepend="__MANAGED_PREPEND_PATH__"
__nucleus_append="__MANAGED_APPEND_PATH__"
__nucleus_managed_set="__MANAGED_DEDUP_SET__"

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

# ── All other GUI env vars (user and non-user) ──
__MACOS_ALL_VARS__

# Set persistent per-user launchd PATH for LaunchServices .app bundles.
# Uses user.plist (not system.plist) because the PATH contains user-specific
# directories.
__desired_path="__MANAGED_LAUNCHCTL_CONFIG_PATH__"
__current_path="$(/usr/libexec/PlistBuddy -c 'Print PathEnvironmentVariable' /private/var/db/com.apple.xpc.launchd/config/user.plist 2>/dev/null || true)"  # undoc-supp: user.plist may not exist before first launchctl config write; read fails gracefully

if [ "$__current_path" != "$__desired_path" ]; then
  echo "launchd: updating user PATH (current differs from desired)."
  if /usr/bin/sudo /bin/launchctl config user path "$__desired_path" 2>/dev/null; then
    echo "launchd: user PATH updated via launchctl config user path."
    echo "launchd: REBOOT REQUIRED for .app bundles to inherit the new PATH."
  else
    echo "launchd: failed to update user PATH (non-fatal)." >&2
  fi
else
  echo "launchd: user PATH already up-to-date."
fi
