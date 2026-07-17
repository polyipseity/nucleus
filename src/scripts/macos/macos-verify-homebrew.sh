    # Warning-only check that installed Homebrew versions match lockfile.  Runs
    # after homebrew bundle (so the cellar is populated) but before other
    # post-install scripts.  Never fails activation.
    #
    # undoc-supp: warning-only version check; must not abort activation even if Homebrew state does not match lockfile or the script encounters an error.
    # NUCLEUS_REPO_ROOT is set by apply.sh and forwarded through sudo. If unset, skip gracefully.
    hb_repo_root="$NUCLEUS_REPO_ROOT"
    if [ -n "$hb_repo_root" ] && [ -f "$hb_repo_root/src/scripts/macos/verify-homebrew-unpinnable.sh" ]; then
      NUCLEUS_REPO_ROOT="$hb_repo_root" sh "$hb_repo_root/src/scripts/macos/verify-homebrew-unpinnable.sh" || true  # undoc-supp: warning-only version check; must not abort activation even if script errors.
    fi
