#!/usr/bin/env bash
    # Reduce GIMP zoom sensitivity to 25% of upstream default by setting the
    # drag-zoom-speed token in the active user gimprc to 25.0 (default 100.0).
    #
    # Why this token: GIMP upstream exposes drag-zoom-speed as a persisted
    # display config token.  Mouse-wheel zoom on macOS uses native scroll
    # deltas and does not have an equivalent persisted sensitivity token.
    # This hook therefore converges the closest supported persistent control.
    #
    # Version tracking rule: always target the major.minor branch of the GIMP
    # app provisioned by Nucleus (/Applications/GIMP.app), rather than using a
    # hardcoded version list, so new app upgrades keep working automatically.
    if _nucleus_resolve_console_user; then
      # shellcheck disable=SC2154 # reason: set by _nucleus_resolve_console_user from Nix-prepended macos-console-user-lib.sh
      console_home="$(/usr/bin/dscl . -read "/Users/$_nucleus_console_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
      if [ -z "$console_home" ]; then
        console_home="/Users/$_nucleus_console_user"
      fi

      # undoc-supp: id -gn may fail if console session ended; empty group is handled by downstream chown guards.
      console_group="$(/usr/bin/id -gn "$_nucleus_console_user" 2>/dev/null || true)"

      gimp_app_info="/Applications/GIMP.app/Contents/Info"
      gimp_version_raw=""
      if [ -d "/Applications/GIMP.app" ]; then
        # undoc-supp: GIMP may not be deployed yet; version probe expected to fail.
        gimp_version_raw="$(/usr/bin/defaults read "$gimp_app_info" CFBundleShortVersionString 2>/dev/null || true)"
      fi

      # Derive major.minor branch used by GIMP's config directory layout,
      # e.g. 3.2.4 -> 3.2
      gimp_version_branch="$(printf '%s' "$gimp_version_raw" | /usr/bin/awk -F. 'NF >= 2 { print $1 "." $2 }')"
      if [ -z "$gimp_version_branch" ]; then
        echo "gimp: unable to determine installed GIMP major.minor version from /Applications/GIMP.app; skipping sensitivity convergence." >&2
      else
        gimprc_dir="$console_home/Library/Application Support/GIMP/$gimp_version_branch"
        gimprc_file="$gimprc_dir/gimprc"

        if ! /bin/mkdir -p "$gimprc_dir"; then
          echo "gimp: failed to create $gimprc_dir." >&2
        else
          if [ ! -f "$gimprc_file" ]; then
            if ! /usr/bin/touch "$gimprc_file"; then
              echo "gimp: failed to create $gimprc_file." >&2
            fi
          fi

          if [ -f "$gimprc_file" ]; then
            # Keep all other user settings intact: only replace or append the
            # drag-zoom-speed token.
            if /usr/bin/grep -Eq '^\(drag-zoom-speed[[:space:]]+[^)]*\)$' "$gimprc_file"; then
              if ! /usr/bin/sed -E -i.bak 's#^\(drag-zoom-speed[[:space:]]+[^)]*\)$#(drag-zoom-speed 25.0)#' "$gimprc_file"; then
                echo "gimp: failed to update drag-zoom-speed in $gimprc_file." >&2
              fi
              /bin/rm -f "$gimprc_file.bak"
            else
              if ! printf '\n(drag-zoom-speed 25.0)\n' >> "$gimprc_file"; then
                echo "gimp: failed to append drag-zoom-speed to $gimprc_file." >&2
              fi
            fi

            if [ -n "$console_group" ]; then
              if ! /usr/sbin/chown "$_nucleus_console_user:$console_group" "$gimprc_file"; then
                echo "gimp: failed to set ownership on $gimprc_file." >&2
              fi
            else
              if ! /usr/sbin/chown "$_nucleus_console_user" "$gimprc_file"; then
                echo "gimp: failed to set ownership on $gimprc_file." >&2
              fi
            fi
          fi
        fi
      fi
    fi
