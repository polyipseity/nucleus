# macOS-only activation hooks and LaunchAgents.
{
  config,
  lib,
  pkgs,
  username,
  nucleusApps,
  users ? null,
  ...
}:
let
  # Activation scripts resolve the repo root from $NUCLEUS_REPO_ROOT (set by apply.sh
  # and forwarded through sudo), so out-of-store symlinks survive repo relocations
  # and rebuilds without stale store paths.  As a fallback, capture NUCLEUS_REPO_ROOT
  # at eval time (where the env var IS available) so home-manager activation,
  # which runs as the user and does not inherit the sudo-level env var, can still
  # locate the repo root.
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  liveICloudDownloads = "${config.home.homeDirectory}/Library/Mobile Documents/com~apple~CloudDocs/Downloads";

  # Sub-module imports extracted from this file for focused maintainability.
  daemonRefresh = import ./macos/daemon-refresh.nix;
  finderSidebar = import ./macos/finder-sidebar.nix { inherit config lib pkgs; };
  preferenceGc = import ./macos/preference-gc.nix { inherit config lib pkgs; };

  # Cached imports for all env-var-related callsites below.
  # managed-paths.nix for PATH components; env-catalog.nix for catalog/resolution.
  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVars = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  # ── Managed dirs dedup SET helper ──────────────────────────────────
  # Returns a colon-joined string of ALL managed dirs (both prepend and
  # append) for use as a case-pattern LOOKUP SET when stripping stale
  # entries from the current PATH before re-adding them.
  # This joins prepend+append as a SET for dedup — NOT as a PATH ordering.
  # The order within the returned string is irrelevant; only membership
  # matters.  The prefix argument is "${config.home.homeDirectory}" for
  # the activation script (build-time eval) or "$HOME" for the launchd
  # agent (runtime shell expansion).
  # Used by guiEnvAgent and guiEnvActivationPathAndRepoRoot (secondary
  # launchctl setenv mechanism); also informs the primary launchctl
  # config system path composition via pathComponents.
  mkManagedDedupSet =
    prefix:
    builtins.concatStringsSep ":" (
      map (p: "${prefix}/${p}") (
        managedPaths.pathComponents.prepend ++ managedPaths.pathComponents.append
      )
    );

  # Shared BD CLI wrapper: soft-fail wrapper for BetterDisplay CLI commands.
  # Used by both betterdisplayHeartbeat and ensureHeadlessDisplay.
  bdCliWrapper = ''
    # _bd_cli args... — Execute BetterDisplay CLI command, soft-fail on error.
    _bd_cli() {
      # undoc-supp: BetterDisplay may be unresponsive during app startup/update, or Pro-only features may be unavailable in the free-tier build. Neither condition should abort activation or mark the LaunchAgent as failed.
      "$BD_BIN" "$@" || true
    }
  '';

  # UTI list for Chrome: set as the default handler for HTML and XHTML documents.: set as the default handler for HTML and XHTML documents.
  # Source: Apple Uniform Type Identifiers.
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  chromeUTIs = [
    "public.html"
    "public.xhtml"
  ];

  # UTI list for Keka: covers 7z, RAR, and ZIP archive formats so that opening
  # any archive file launches Keka for graphical extraction/creation.
  # Sources:
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  # https://github.com/moretension/duti
  kekaUTIs = [
    "public.zip-archive"
    "com.rarlab.rar-archive"
  ];

  # UTI list for VLC: covers the full range of video, audio, and playlist
  # formats that VLC supports so that double-clicking any media file opens VLC.
  # Sources:
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  # https://github.com/moretension/duti
  vlcUTIs = [
    "public.movie"
    "public.video"
    "public.audio"
    "public.audiovisual-content"
    "public.mp3"
    "public.mpeg"
    "public.mpeg-4"
    "public.mpeg-2-video"
    "public.mpeg-2-transport-stream"
    "com.apple.quicktime-movie"
    "com.apple.m4a-audio"
    "com.apple.m4v-video"
    "public.avi"
    "public.3gpp"
    "public.3gpp2"
    "org.xiph.flac"
    "org.matroska.mka"
    "org.matroska.mkv"
    "org.videolan.webm"
    "org.xiph.ogg-audio"
    "org.xiph.ogg-video"
    "org.xiph.opus"
    "com.microsoft.advanced-systems-format"
    "com.real.realaudio"
    "com.real.realmedia"
    "public.dv-movie"
    "org.smpte.mxf"
    "public.flc-animation"
    "public.aiff-audio"
    "com.microsoft.waveform-audio"
    "public.aifc-audio"
    "com.apple.coreaudio-format"
    "public.m3u-playlist"
    "public.pls-playlist"
  ];

  # Absolute path to the duti binary supplied by nixpkgs.
  dutiBin = "${pkgs.duti}/bin/duti";

  # Periodic heartbeat script for the BetterDisplay virtual screen.
  # Lives in the Nix store so the LaunchAgent ProgramArguments path is stable
  # across home-manager generations without a home.file symlink.
  # set +e at the top makes all operations fully soft-fail so launchd never
  # marks the agent as failed and throttles future invocations.
  #
  # Restrict iCloud exclusion to ~/Library/Mobile Documents subpaths.
  # Never traverse symlinks like ~/Downloads/iCloud or ~/clouds/iCloud.
  sanitizeICloudManagedRoots =
    roots:
    let
      normalizeRoot = root: lib.removeSuffix "/." root;
      normalizedRoots = map normalizeRoot roots;
      mobileDocumentsRoots = builtins.filter (
        root: root != "Library/Mobile Documents" && lib.hasPrefix "Library/Mobile Documents/" root
      ) normalizedRoots;
    in
    if mobileDocumentsRoots != [ ] then
      mobileDocumentsRoots
    else
      [ "Library/Mobile Documents/com~apple~CloudDocs" ];

  # Pre-computed JSON payloads for the iCloud exclusions launchd script.
  # Evaluated at derivation time so the standalone script can be placed in the
  # Nix store without needing runtime user-context access.  Both values mirror
  # the inline computation in configureICloudExclusions to keep the activation
  # hook and the daily launchd agent in sync.
  icloudExcludedDirsJson = builtins.toJSON (
    let
      effectiveUsers = if users != null then users else { };
      currentUser = config.home.username;
    in
    if
      builtins.hasAttr currentUser effectiveUsers
      && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
      && builtins.hasAttr "excludedDirNames" effectiveUsers.${currentUser}.iCloudExclusions
    then
      effectiveUsers.${currentUser}.iCloudExclusions.excludedDirNames
    else
      [ ]
  );

  icloudManagedRootsJson = builtins.toJSON (
    let
      effectiveUsers = if users != null then users else { };
      currentUser = config.home.username;
    in
    if
      builtins.hasAttr currentUser effectiveUsers
      && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
      && builtins.hasAttr "managedRoots" effectiveUsers.${currentUser}.iCloudExclusions
    then
      sanitizeICloudManagedRoots effectiveUsers.${currentUser}.iCloudExclusions.managedRoots
    else
      sanitizeICloudManagedRoots [ ]
  );

  # Shared shell body for iCloud exclusion convergence, used by both the
  # synchronous activation hook and the daily launchd maintenance script.
  # Keep this as one source of truth so behavior stays aligned.
  icloudExclusionsShellBody = excludedDirs: managedRoots: ''
    excluded_dirs=${lib.escapeShellArg excludedDirs}
    managed_roots=${lib.escapeShellArg managedRoots}

    if [ "$excluded_dirs" = "[]" ]; then
      echo "macos: iCloud exclusions skipped (no excluded directory names configured)." >&2
      return 0 2>/dev/null || exit 0
    fi

    apply_exclusions() {
      local count=0
      local start_time
      start_time=$(date +%s)

      while IFS= read -r rel_root; do
        [ -z "$rel_root" ] && continue
        icloud_root="$HOME/$rel_root"
        [ -d "$icloud_root" ] || continue

        find_args=()
        first=1
        while IFS= read -r dir_name; do
          [ -z "$dir_name" ] && continue
          if [ "$first" -eq 1 ]; then
            find_args=( "(" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune" )
            first=0
          else
            find_args+=( "-o" "-name" "$dir_name" "-exec" "/usr/bin/xattr" "-w" "com.apple.fileprovider.ignore#P" "1" "{}" ";" "-prune" )
          fi
        done < <(echo "$excluded_dirs" | ${pkgs.jq}/bin/jq -r '.[]' 2>/dev/null)

        if [ "$first" -eq 1 ]; then
          continue
        fi

        find_args+=( ")" )

        count_batch=$(${pkgs.findutils}/bin/find "$icloud_root" -type d "''${find_args[@]}" -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || count_batch=0
        count=$(( count + count_batch ))
      done < <(echo "$managed_roots" | ${pkgs.jq}/bin/jq -r '.[]' 2>/dev/null)

      end_time=$(date +%s)
      elapsed=$(( end_time - start_time ))

      if [ "$count" -gt 0 ]; then
        echo "macos: iCloud exclusion applied to $count directories in ''${elapsed}s" >&2
      fi
    }

    apply_exclusions
  '';

  # Shared FDA warning printer used by domain-specific defaults hooks.
  mkFdaWarningFunction = target: ''
    print_fda_warning() {
      if [ "$fda_warning_emitted" -eq 1 ]; then
        return
      fi

      bold="$(printf '\033[1m')"
      red="$(printf '\033[31m')"
      reset="$(printf '\033[0m')"
      yellow="$(printf '\033[33m')"

      printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
      printf '%sNucleus cannot write ${target} from this terminal session.%s\n' "$yellow" "$reset" >&2
      printf '%s\n' "To fix this:" >&2
      printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
      printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
      printf '  3. If already enabled, remove and re-add it, then restart the terminal\n' >&2

      fda_warning_emitted=1
    }
  '';

  # Standalone script for the daily icloud-exclusions LaunchAgent.
  # Uses bash (from the Nix store) rather than /bin/sh because the array-based
  # find-predicate builder and process substitution (< <(...)) require bash
  # semantics that macOS /bin/sh (zsh in POSIX mode) does not provide.
  # Logic mirrors configureICloudExclusions so both paths stay in sync.
  # Source: https://developer.apple.com/documentation/fileprovider
  icloudExclusionsScript = pkgs.writeTextFile {
    name = "icloud-exclusions";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -eu

      ${icloudExclusionsShellBody icloudExcludedDirsJson icloudManagedRootsJson}
    '';
  };

  betterdisplayHeartbeat = pkgs.writeShellScript "betterdisplay-heartbeat" ''
    set +e  # heartbeat is fully soft-fail; never abort on individual check failure

    BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    BD_APP="/Applications/BetterDisplay.app"
    DISPLAY_NAME="HeadlessDisplay"

    ${bdCliWrapper}

    # Persistent daemon loop: check every 30 s.
    while true; do
      # No-op if BetterDisplay is not installed.
      if [ ! -f "$BD_BIN" ]; then
        sleep 30
        continue
      fi

      # Ensure BetterDisplay is running before issuing CLI commands.
      if ! /usr/bin/pgrep -xq "BetterDisplay" 2>/dev/null; then
        # undoc-supp: BetterDisplay may not be installed yet; best-effort launch.
        /usr/bin/open -g -a "$BD_APP" || true
        /bin/sleep 5
      fi

      # Check connection state; soft-fail by treating any CLI error as unknown.
      connected_state="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"

      # No-op if already connected.
      if [ "$connected_state" = "on" ]; then
        sleep 30
        continue
      fi

      # Virtual screen is disconnected or status is unknown.  Try the lightweight
      # set -connected=on toggle first; it is free-tier-compatible for virtual
      # screens (Pro gating applies only to physical display connection toggles).
      # If the toggle fails, fall back to a discard-and-recreate using the same
      # parameters as ensureHeadlessDisplay so the virtual screen specification
      # stays consistent across both code paths.
      if ! "$BD_BIN" set -name="$DISPLAY_NAME" -connected=on; then
        tag_ids="$(_bd_cli get -identifiers -name="$DISPLAY_NAME" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        for tag_id in $tag_ids; do
          _bd_cli discard -tagID="$tag_id"
        done
        _bd_cli create \
          -type=VirtualScreen \
          -virtualScreenName="$DISPLAY_NAME" \
          -aspectWidth=16 \
          -aspectHeight=10 \
          -multiplierStep=160 \
          -virtualScreenHiDPI=on \
          -connected=on
      fi

      sleep 30
    done
  '';

  # Wrapper script for the nix-index daily database rebuild LaunchAgent.
  # Lives in the Nix store so the ProgramArguments path is stable across
  # home-manager generations without a home.file symlink.
  #
  # A freshness check prevents a full rebuild on every home-manager switch:
  # the LaunchAgent is reloaded on each switch because its plist embeds the
  # Nix store derivation path (which changes per generation).  Skipping the
  # rebuild when the DB was updated within the past 6 days keeps normal
  # apply runs fast.
  nixIndexUpdate = pkgs.writeShellScript "nix-index-update" ''
    db_file="$HOME/.cache/nix-index/files"

    # Skip rebuild when the DB file exists and was modified within the last
    # 6 days.  find -mtime +6 matches files with modification time strictly
    # greater than 6x24 h ago; empty output means the file is still fresh.
    if [ -f "$db_file" ] && [ -z "$(find "$db_file" -mtime +6)" ]; then
      exit 0
    fi

    exec ${pkgs.nix-index}/bin/nix-index
  '';

  # Directory names inside ~/dev whose contents should stay out of Spotlight.
  # This is intentionally macOS-only because `.metadata_never_index` is a
  # Finder/Spotlight convention, not a cross-host filesystem primitive.
  devSpotlightExcludedDirectoryNames = [
    ".gradle"
    ".next"
    ".turbo"
    ".venv"
    "__pycache__"
    "bin"
    "build"
    "dist"
    "incremental"
    "node_modules"
    "obj"
    "target"
    "vendor"
    "venv"
  ];

  # Single-pass find predicate for low-signal build/cache directories in ~/dev.
  # Precompute the expression in Nix so the launchd job shell stays readable.
  devSpotlightExcludedDirectoryFindExpression = builtins.concatStringsSep " -o " (
    map (directoryName: "-name ${lib.escapeShellArg directoryName}") devSpotlightExcludedDirectoryNames
  );

  # Daily Spotlight exclusion refresh for the mutable ~/dev tree.
  # Kept out of Home Manager activation because large worktrees can make a full
  # scan slow enough to noticeably delay `nix run .#apply` and bootstrap apply.
  devSpotlightExclusions = pkgs.writeShellScript "dev-spotlight-exclusions" ''
    set -eu

    DEV_ROOT="$HOME/dev"
    updated_count=0

    # Create the canonical dev root lazily so the maintenance timer remains
    # safe even before the first repo checkout populates ~/dev.
    mkdir -p "$DEV_ROOT"

    while IFS= read -r -d "" directory_path; do
      marker_path="$directory_path/.metadata_never_index"
      if [ -f "$marker_path" ]; then
        continue
      fi

      : > "$marker_path"
      updated_count=$((updated_count + 1))
    done < <(
      /usr/bin/find "$DEV_ROOT" \( ${devSpotlightExcludedDirectoryFindExpression} \) -type d -print0
    )

    if [ "$updated_count" -gt 0 ]; then
      echo "macos: added Spotlight exclusion markers to $updated_count dev directories." >&2
    fi
  '';

  # Daily Finder metadata cleanup for ~/dev.
  # Kept out of Home Manager activation for the same reason as Spotlight marker
  # maintenance: deleting stale .DS_Store files can take noticeable time on a
  # large checkout and should not slow synchronous apply/bootstrap flows.
  devDsStoreGc = pkgs.writeShellScript "dev-ds-store-gc" ''
    set -eu

    DEV_ROOT="$HOME/dev"
    removed_count=0

    # Create the canonical dev root lazily so the maintenance timer remains
    # safe even before the first repo checkout populates ~/dev.
    mkdir -p "$DEV_ROOT"

    while IFS= read -r -d "" ds_store_path; do
      /bin/rm "$ds_store_path"
      removed_count=$((removed_count + 1))
    done < <(
      /usr/bin/find "$DEV_ROOT" -name ".DS_Store" -type f -print0
    )

    if [ "$removed_count" -gt 0 ]; then
      echo "macos: removed $removed_count .DS_Store files from ~/dev." >&2
    fi
  '';

  gcWeekly = pkgs.writeShellScript "gc-weekly" ''
    set -eu

    # Eval-time fallback for launchd jobs that don't inherit apply.sh env.
    _repo_root="${repoRoot}"
    if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
      _repo_root="''${NUCLEUS_REPO_ROOT:?gc: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
    fi

    if [ ! -f "$_repo_root/scripts/gc.sh" ]; then
      echo "gc: scripts/gc.sh not found at $_repo_root; skipping weekly GC"
      exit 1
    fi

    # Weekly GC is space-reclaim only; skip model pulls and skip any operations
    # that would block the background launchd job (like waiting for Ollama).
    # GC script handles tool availability checks internally.
    exec "$_repo_root/scripts/gc.sh"
  '';

  guiEnvAgent = pkgs.writeShellScript "gui-env-agent" ''
    set -eu

    # Persistent daemon loop: re-apply env vars every 300 s.
    # Internal loop (not StartInterval) so the interval is visible in the
    # script and survives launchd throttle limits.  KeepAlive=true provides
    # crash recovery.
    #
    # PATH PROPAGATION (dual mechanism):
    # - Primary (LaunchServices .app bundles): launchctl config system path
    #   in MacBook/activation.nix. Reboot required on first set.
    # - Secondary (launchd-direct, XPC services, non-LaunchServices): this
    #   launchctl setenv call below. Provides immediate coverage until reboot.
    while true; do
      # ── PATH: strip stale managed entries, then prepend+append (secondary) ──
      __nucleus_prepend="${managedPaths.toLaunchctlPrependPath}"
      __nucleus_append="${managedPaths.toLaunchctlAppendPath}"
      # Same dedup SET as the activation script, but using $HOME (runtime
      # shell expansion by launchd) instead of build-time home directory.
      __nucleus_managed_set="${mkManagedDedupSet "$HOME"}"

      __nucleus_cleaned=""
      old_IFS="$IFS"
      IFS=:
      for __component in $PATH; do
        case ":''${__nucleus_managed_set}:" in
          *":''${__component}:"*) ;;
          *) __nucleus_cleaned="''${__nucleus_cleaned}:''${__component}" ;;
        esac
      done
      IFS="$old_IFS"

      if [ -n "$__nucleus_cleaned" ]; then
        /bin/launchctl setenv PATH "''${__nucleus_prepend}:''${__nucleus_cleaned}:''${__nucleus_append}"
      else
        /bin/launchctl setenv PATH "''${__nucleus_prepend}:''${__nucleus_append}"
      fi

      # ── All other GUI env vars (user and non-user) ──
      ${envVars.macOSAllVars}

      sleep 300
    done
  '';
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [
    preferenceGc.managedPreferencesGcScript
    pkgs.mysides
  ];

  home.file = {
    # Keep iCloud Downloads reachable from a short stable path without
    # replacing ~/Downloads itself.
    "Downloads/iCloud".source = config.lib.file.mkOutOfStoreSymlink liveICloudDownloads;
  };

  home.activation.unprotectDownloadsICloudSymlink = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/agent-helpers.sh}
    _nucleus_unprotect_symlink "macos.nix" "$HOME/Downloads/iCloud"
  '';

  home.activation.protectDownloadsICloudSymlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/agent-helpers.sh}
    _nucleus_protect_symlink "macos.nix" "$HOME/Downloads/iCloud"
  '';

  home.activation = {
    # -------------------------------------------------------------------------
    # configureDisplayResolutions
    # Uses displayplacer to match all external monitors to the MacBook's built-in
    # display mode so that remote-desktop clients see a consistent resolution.
    #
    # Algorithm:
    #   1. Identify the built-in screen's persistent ID and its current mode.
    #   2. If the built-in is on mode 4 (high-DPI Retina mode), apply it first
    #      to ensure the reference resolution is set correctly.
    #   3. Re-read the current mode string to obtain target width/height and
    #      the scaling flag.
    #   4. For each external display, find the mode whose width ≥ target width
    #      and height ≤ target height (so it fits within the same logical area)
    #      with the smallest height (closest match without overshooting).
    #
    # No-op if displayplacer is not installed.
    # -------------------------------------------------------------------------
    configureDisplayResolutions = lib.hm.dag.entryAfter [ "ensureHeadlessDisplay" ] ''
      DP_BIN="/opt/homebrew/bin/displayplacer"

      if [ -x "$DP_BIN" ]; then
        FULL_LIST=$("$DP_BIN" list)

        # Locate the persistent ID of the built-in MacBook screen.
        PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/awk '
          /^Persistent screen id:/ { last_id=$4 }
          /Type: MacBook built in screen/ { print last_id; exit }
        ')

        # Fall back to the first listed display if the built-in label is absent.
        if [ -z "$PRIMARY_ID" ]; then
          PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/head -n 1 | /usr/bin/awk '{print $4}')
        fi

        # Read the mode 4 string for the primary display (native HiDPI mode).
        MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /^  mode 4:/ {
            sub(/^[ ]*mode 4: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

        # If mode 4 is not available, read whichever mode is currently active.
        if [ -z "$MODE4_STR" ]; then
          MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
            $0 ~ id { found=1 }
            found && /<-- current mode/ {
              sub(/^[ ]*mode [0-9]+: /, "");
              sub(/[ ]*<-- current mode/, "");
              print $0;
              exit;
            }
          ')
        fi

        # Apply the target mode on the primary display and refresh the list.
        if [ -n "$MODE4_STR" ]; then
          if ! "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR"; then
            echo "macos: failed to apply primary display mode with displayplacer." >&2
          fi
          /bin/sleep 1
          FULL_LIST=$("$DP_BIN" list)
        fi

        # Read the mode that is now active on the primary display to use as
        # the reference resolution for external monitors.
        TARGET_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /<-- current mode/ {
            sub(/^[ ]*mode [0-9]+: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

        # Extract width, height, and scaling flag from the target mode string.
        T_W=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:([0-9]+)x.*/\1/')
        T_H=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:[0-9]+x([0-9]+).*/\1/')
        T_SCALING=""
        if echo "$TARGET_STR" | /usr/bin/grep -q "scaling:on"; then
          T_SCALING="scaling:on"
        fi

        # For each external display, select the best matching mode and apply it.
        for ID in $(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/awk '{print $4}'); do
          if [ "$ID" = "$PRIMARY_ID" ]; then
            continue
          fi

          MODES=$(echo "$FULL_LIST" | /usr/bin/sed -n "/^Persistent screen id: $ID/,/^Persistent screen id:/p" | /usr/bin/grep "^  mode " | /usr/bin/sed 's/^  mode [0-9]*: //')
          # When the primary uses HiDPI scaling, restrict candidates to HiDPI modes.
          if [ -n "$T_SCALING" ]; then
            MODES=$(echo "$MODES" | /usr/bin/grep "scaling:on")
          fi

          # Pick the mode with the smallest height that is still ≥ target width
          # and ≤ target height (fits the same logical area, highest PPI wins).
          BEST_MODE=$(echo "$MODES" | /usr/bin/awk -v tw="$T_W" -v th="$T_H" '{ w=substr($0,index($0,"res:")+4); gsub(/[^0-9].*/,"",w); h=substr($0,index($0,"x")+1); gsub(/[^0-9].*/,"",h); if (w+0>=tw+0 && h+0<=th+0 && h+0>0) print w+0, h+0, $0 }' | /usr/bin/sort -n | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f3- | /usr/bin/sed 's/ <-- current mode$//')

          if [ -n "$BEST_MODE" ]; then
            if ! "$DP_BIN" "id:$ID $BEST_MODE"; then
              echo "macos: failed to apply mode '$BEST_MODE' to display id $ID." >&2
            fi
          fi
        done
      fi
    '';

    # -------------------------------------------------------------------------
    # configureInputAndSiri
    # Writes input-method defaults that cannot be expressed in the nix-darwin
    # system.defaults tree because they require a running input method daemon
    # reload to take effect at session time.
    #
    #   hotkey 176 disabled  — disable the built-in "Move focus to next window"
    #                          shortcut that conflicts with custom window managers.
    #                          Uses -dict-add (merge), which cannot be expressed
    #                          as a plain defaults write in CustomUserPreferences.
    #   activateSettings -u  — flush keyboard/input settings into the running session
    #   killall TISwitcher   — restart the input-source switcher daemon so changes
    #                          to TISCapslockLanguageSwitch / FnKeyUsage take effect
    #
    # TISCapslockLanguageSwitch, AppleDictationAutoEnable, and FnKeyUsage are
    # now handled declaratively in defaults.nix via CustomUserPreferences.
    # -------------------------------------------------------------------------
    configureInputAndSiri = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Source: symbolic hotkey values are persisted in
      # com.apple.symbolichotkeys/AppleSymbolicHotKeys via defaults(1).
      # https://www.manpagez.com/man/1/defaults/
      if ! /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>"; then
        echo "macos: failed to update symbolic hotkey 176." >&2
      fi

      if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
        echo "macos: activateSettings -u failed; input settings may apply on next login." >&2
      fi

      ${daemonRefresh.refreshTISwitcher}
    '';

    # -------------------------------------------------------------------------
    # reloadUserPreferenceState
    # Forces macOS to flush/reload user defaults after all managed defaults
    # writes and domain-specific hooks.  This minimizes "ghost" values staying
    # in memory until logout/login after a rebuild.
    # -------------------------------------------------------------------------
    reloadUserPreferenceState =
      lib.hm.dag.entryAfter
        [ "configureInputAndSiri" "configureSafariDefaults" "configureUniversalAccessDefaults" ]
        ''
          if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
            echo "macos: activateSettings -u failed; some preference updates may require relogin." >&2
          fi
        '';

    # -------------------------------------------------------------------------
    # configureLinearmouseConfig
    # Creates out-of-store symlinks for LinearMouse's runtime config files
    # pointing into the repository tree. Resolves the repo root at activation
    # time so the link survives repo relocations and rebuilds without stale
    # store paths.
    # -------------------------------------------------------------------------
    configureLinearmouseConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      _ll_repo_root="${repoRoot}"
      if [ -z "$_ll_repo_root" ] || [ ! -d "$_ll_repo_root" ]; then
        _ll_repo_root="''${NUCLEUS_REPO_ROOT:?LinearMouse: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
      fi
      _ll_source="$_ll_repo_root/src/modules/configs/linearmouse/linearmouse.json"

      mkdir -p "$HOME/.config/linearmouse"
      mkdir -p "$HOME/Library/Application Support/linearmouse"
      ln -sf "$_ll_source" "$HOME/.config/linearmouse/linearmouse.json"
      ln -sf "$_ll_source" "$HOME/Library/Application Support/linearmouse/linearmouse.json"
    '';

    # -------------------------------------------------------------------------
    # configureLaunchServices
    # Registers default application handlers for file types using duti.
    # Running this in a Home Manager activation keeps the associations in sync
    # every time `home-manager switch` is run, which is necessary because
    # application (re)installs can reset handler registrations.
    #
    #   Chrome — handles all HTML/XHTML documents
    #   Keka   — handles .7z, .rar, and .zip archives
    #   VLC    — handles the complete set of audio/video UTIs defined above
    # -------------------------------------------------------------------------
    configureLaunchServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # register_handler BUNDLE_ID UTI [UTI ...]
      # Sets BUNDLE_ID as the default handler for each UTI across all roles.
      register_handler() {
        handler="$1"
        shift

        for uti in "$@"; do
          if ! "${dutiBin}" -s "$handler" "$uti" all; then
            echo "macos: failed to register LaunchServices handler $handler for UTI $uti." >&2
          fi
        done
      }

      # Bundle identifiers sourced from app bundles + vendor docs:
      # - Chrome: com.google.chrome
      #   https://chromeenterprise.google/policies/
      # - Keka: com.aone.keka
      #   https://www.keka.io/en/
      # - VLC: org.videolan.vlc
      #   https://wiki.videolan.org/MacOS/
      register_handler "com.google.chrome" ${builtins.concatStringsSep " " chromeUTIs}
      register_handler "com.aone.keka" ${builtins.concatStringsSep " " kekaUTIs}
      register_handler "org.videolan.vlc" ${builtins.concatStringsSep " " vlcUTIs}
    '';

    # -------------------------------------------------------------------------
    # configureRaycastApplicationAliases
    # Raycast currently does not expose a dedicated language toggle for app-name
    # matching. On non-English macOS installations, localized display names can
    # therefore make English queries miss built-in apps.
    #
    # Mitigation: publish a managed set of English-named .app symlink aliases
    # under ~/Applications/Nucleus App Aliases so Spotlight/Raycast can index
    # additional English tokens without changing the system UI language.
    # -------------------------------------------------------------------------
    configureRaycastApplicationAliases = lib.hm.dag.entryAfter [ "configureLaunchServices" ] ''
      _ray_alias_dir="$HOME/Applications/Nucleus App Aliases"
      mkdir -p "$_ray_alias_dir"
      ${builtins.readFile ../scripts/agent-helpers.sh}

      ensure_alias() {
        _alias_name="$1"
        _target_app="$2"
        _alias_path="$_ray_alias_dir/$_alias_name"

        [ -e "$_target_app" ] || return 0

        if [ -L "$_alias_path" ]; then
          if [ "$(readlink "$_alias_path")" = "$_target_app" ]; then
            _nucleus_protect_symlink "raycast" "$_alias_path"
            return 0
          fi
          _nucleus_unprotect_symlink "raycast" "$_alias_path"
          rm "$_alias_path"
        elif [ -e "$_alias_path" ]; then
          echo "raycast: keeping unmanaged app alias path $_alias_path (not a symlink)." >&2
          return 0
        fi

        ln -s "$_target_app" "$_alias_path"
        _nucleus_protect_symlink "raycast" "$_alias_path"
      }

      ensure_alias "Books (English).app" "/System/Applications/Books.app"
      ensure_alias "Calculator (English).app" "/System/Applications/Calculator.app"
      ensure_alias "Calendar (English).app" "/System/Applications/Calendar.app"
      ensure_alias "Contacts (English).app" "/System/Applications/Contacts.app"
      ensure_alias "FaceTime (English).app" "/System/Applications/FaceTime.app"
      ensure_alias "Find My (English).app" "/System/Applications/FindMy.app"
      ensure_alias "Freeform (English).app" "/System/Applications/Freeform.app"
      ensure_alias "Home (English).app" "/System/Applications/Home.app"
      ensure_alias "Mail (English).app" "/System/Applications/Mail.app"
      ensure_alias "Maps (English).app" "/System/Applications/Maps.app"
      ensure_alias "Messages (English).app" "/System/Applications/Messages.app"
      ensure_alias "Music (English).app" "/System/Applications/Music.app"
      ensure_alias "Notes (English).app" "/System/Applications/Notes.app"
      ensure_alias "Photos (English).app" "/System/Applications/Photos.app"
      ensure_alias "Reminders (English).app" "/System/Applications/Reminders.app"
      ensure_alias "Safari (English).app" "/Applications/Safari.app"
      ensure_alias "TV (English).app" "/System/Applications/TV.app"
      ensure_alias "Weather (English).app" "/System/Applications/Weather.app"
    '';

    # -------------------------------------------------------------------------
    # configureNightlight
    # Enables the macOS Night Shift schedule via the nightlight CLI tool and
    # applies a colour temperature of 50 % (roughly 4000 K).  Immediately
    # activates or deactivates the filter based on the current hour so the
    # display is always in the correct state right after an activation.
    #
    # Schedule: 18:00 → 06:00 (nightlight schedule start uses default times).
    # No-op if nightlight is not installed.
    # Source: https://github.com/smudge/nightlight
    # -------------------------------------------------------------------------
    configureNightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [ -x "/opt/homebrew/bin/nightlight" ]; then
        if ! /opt/homebrew/bin/nightlight schedule start; then
          echo "macos: failed to configure Nightlight schedule." >&2
        fi

        if ! /opt/homebrew/bin/nightlight temp 50; then
          echo "macos: failed to set Nightlight temperature." >&2
        fi

        current_hour=$(date +%H)
        if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
          if ! /opt/homebrew/bin/nightlight on; then
            echo "macos: failed to enable Nightlight." >&2
          fi
        else
          if ! /opt/homebrew/bin/nightlight off; then
            echo "macos: failed to disable Nightlight." >&2
          fi
        fi
      fi
    '';

    # -------------------------------------------------------------------------
    # configureICloudExclusions
    # Marks directories matching configured names with the com.apple.fileprovider
    # .ignore#P xattr to exclude them from iCloud sync. This prevents large
    # directories (e.g., node_modules, .venv) from syncing across devices.
    #
    # Scope guard:
    #   1. Managed roots come from the centralized users.json registry.
    #   2. At evaluation time we discard any root outside Library/Mobile Documents.
    #   3. At runtime we recurse only inside those native iCloud directories.
    #   4. find -prune stops descent into excluded directories, keeping scans fast.
    #
    # Configuration: excludedDirNames from users.json (e.g., ["node_modules"])
    # Source: https://developer.apple.com/documentation/fileprovider
    # -------------------------------------------------------------------------
    configureICloudExclusions = lib.hm.dag.entryAfter [ "cloudDrivesSetup" ] ''
      ${icloudExclusionsShellBody icloudExcludedDirsJson icloudManagedRootsJson}
    '';

    # -------------------------------------------------------------------------
    # preflightPrivacyPermissions
    # Detects privacy-gated preference access problems early and emits an
    # explicit Full Disk Access remediation block so activation logs explain why
    # subsequent defaults writes may fail.
    #
    # Probe strategy:
    #   1. Attempt a write/delete probe on a privacy-gated domain.
    #   2. If the probe fails with permission text, print a highlighted FDA
    #      guide so later defaults-write failures are actionable.
    #   3. Continue activation either way so non-privacy-gated settings still
    #      converge in the same run.
    # -------------------------------------------------------------------------
    preflightPrivacyPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo "macos: checking macOS privacy permissions before defaults writes..." >&2

      print_fda_warning() {
        bold="$(printf '\033[1m')"
        red="$(printf '\033[31m')"
        reset="$(printf '\033[0m')"
        yellow="$(printf '\033[33m')"

        printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
        printf '%sNucleus detected that this terminal session lacks permission to modify protected user preferences.%s\n' "$yellow" "$reset" >&2
        printf '%s\n' "To fix this:" >&2
        printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
        printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
        printf '  3. Restart the terminal and run activation again\n' >&2
      }

      probe_domain="com.apple.universalaccess"
      probe_key="NucleusActivationProbe"
      if ! probe_err="$({
        /usr/bin/defaults write "$probe_domain" "$probe_key" -bool false
        /usr/bin/defaults delete "$probe_domain" "$probe_key"
      } 2>&1)"; then
        if printf '%s' "$probe_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
          print_fda_warning
        else
          echo "macos: privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes." >&2
        fi
      fi
    '';

    # -------------------------------------------------------------------------
    # configureSafariDefaults
    # Safari is sandboxed and stores preferences in a containerized domain that
    # `system.defaults.CustomUserPreferences` cannot always write during system
    # activation. Apply these settings from user activation instead so Safari
    # hardening remains declarative without breaking `darwin-rebuild switch`.
    # -------------------------------------------------------------------------
    configureSafariDefaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] ''
      fda_warning_emitted=0

      ${mkFdaWarningFunction "protected Safari preferences"}

      set_safari_default() {
        key="$1"
        value="$2"
        value_type="$3"

        if ! write_err="$({ /usr/bin/defaults write com.apple.Safari "$key" "-$value_type" "$value"; } 2>&1)"; then
          if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
            print_fda_warning
            echo "macos: failed to set Safari key $key due to missing privacy authorization." >&2
          else
            echo "macos: failed to set Safari key $key ($write_err)." >&2
          fi
        fi
      }

      # Source: Safari preference behavior.
      # https://support.apple.com/en-us/guide/safari/change-settings-ibrwa005/mac
      set_safari_default "AutoFillPasswords" "false" "bool"
      set_safari_default "IncludeDevelopMenu" "true" "bool"
      set_safari_default "IncludeInternalDebugMenu" "true" "bool"
    '';

    # -------------------------------------------------------------------------
    # configureUniversalAccessDefaults
    # Accessibility defaults are user/session scoped and may be protected from
    # system-level defaults writes during `darwin-rebuild`. Apply them from the
    # user activation phase to keep accessibility intent without system errors.
    # -------------------------------------------------------------------------
    configureUniversalAccessDefaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] ''
      fda_warning_emitted=0

      ${mkFdaWarningFunction "Accessibility preferences"}

      set_default() {
        domain="$1"
        key="$2"
        value="$3"
        value_type="$4"
        yellow="$(printf '\033[33m')"
        bold="$(printf '\033[1m')"
        reset="$(printf '\033[0m')"

        if ! write_err="$({ /usr/bin/defaults write "$domain" "$key" "-$value_type" "$value"; } 2>&1)"; then
          if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
            print_fda_warning
            printf '%s![Permission Denied]%s Failed to set %s%s %s%s. Ensure Full Disk Access and Accessibility permissions are granted.\n' "$yellow" "$reset" "$bold" "$domain" "$key" "$reset" >&2
          else
            echo "macos: failed to set $domain $key ($write_err)." >&2
          fi
        fi
      }

      # Source: macOS Accessibility preference settings.
      # https://support.apple.com/en-us/guide/mac-help/accessibility-settings-on-mac-mh40584/mac
      set_default "com.apple.universalaccess" "FontSizeCategory" "AX1" "string"
      set_default "com.apple.universalaccess" "cursorSize" "1.33" "float"
      set_default "com.apple.universalaccess" "reduceMotion" "false" "bool"
      set_default "com.apple.universalaccess" "reduceTransparency" "false" "bool"
      set_default "com.apple.universalaccess" "showWindowTitlebarIcons" "true" "bool"
    '';

    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    # provisionDevDirectory
    # Ensures ~/dev exists before any dev-tree maintenance runs.
    #
    # WHY separate activation: the directory itself is cross-host provisioning
    # state, while the macOS-only cleanup/indexing steps below are session-side
    # maintenance concerns.
    # -------------------------------------------------------------------------
    provisionDevDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

    # -------------------------------------------------------------------------
    # reloadDockPreferenceState
    # Restarts Dock so declarative Dock defaults take effect immediately.
    #
    # WHY separate activation: Dock refresh is a UI cache reload, not dev-tree
    # maintenance. Keeping it independent avoids fake coupling with ~/dev work.
    # -------------------------------------------------------------------------
    reloadDockPreferenceState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${daemonRefresh.refreshDock}
    '';

    # -------------------------------------------------------------------------
    # configureFinderSidebar
    # Configure Finder favorites via mysides using a deterministic ordered list.
    # Avoids archive-rewrite workarounds; sidebar converges from activation.
    # NOTE: mysides writes to the SFLSharedFileList via com.apple.sharedfilelistd.
    # The daemon caches sidebar state; changes are fully visible in Finder only
    # after a macOS logout/reboot. The daemon restarts below provide a partial
    # in-session flush but a full restart is required for order to appear correctly.
    # Source: https://github.com/mosen/mysides
    configureFinderSidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu

      ${finderSidebar.finderSidebarEnsureDirectoriesShell}

      MYSIDES_BIN="${pkgs.mysides}/bin/mysides"

      if [ ! -x "$MYSIDES_BIN" ]; then
        echo "macos: mysides is unavailable; Finder favorites were not updated automatically." >&2
        exit 0
      fi

      _finder_sidebar_failed=0

      add_favorite() {
        _name="$1"
        _url="$2"

        if ! "$MYSIDES_BIN" add "$_name" "$_url" >/dev/null 2>&1; then
          echo "macos: failed to add Finder favorite '$_name' ($_url)." >&2
          _finder_sidebar_failed=1
        fi
      }

      # Clear current favorites first so the final list order is deterministic.
      # `mysides list` is now considered healthy in this environment.
      # Rebuild the exact managed order requested for Finder favorites.
      ${finderSidebar.finderSidebarRebuildStrictShell}

      _finder_expected_order="${finderSidebar.finderSidebarExpectedOrder}"
      # undoc-supp: mysides list may fail (segfault on corrupted bookmarks); best-effort probe.
      _finder_list_output=$("$MYSIDES_BIN" list 2>/dev/null || true)
      _finder_actual_order="$(echo "$_finder_list_output" | /usr/bin/awk -F' -> ' 'NF >= 1 && $1 != "" { print $1 }' | /usr/bin/head -n ${toString finderSidebar.finderSidebarManagedCount} | /usr/bin/paste -sd'|' -)"
      if [ "$_finder_actual_order" != "$_finder_expected_order" ]; then
        echo "macos: warning — mysides reported sidebar order mismatch (expected: $_finder_expected_order, actual: $_finder_actual_order)." >&2
        _finder_sidebar_failed=1
      fi

      # Refresh finder-related daemons in-session (sharedfilelistd, cfprefsd).
      ${finderSidebar.finderRefreshDaemonsShell}

      if [ "$_finder_sidebar_failed" -eq 1 ]; then
        echo "macos: Finder favorites were partially updated; if stale entries persist, log out and log back in once." >&2
      else
        echo "macos: Finder favorites updated automatically." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # relaunchDesktopServices
    # Single dedicated restart for desktop-related system processes (Finder,
    # SystemUIServer, WindowManager) after all configuration changes complete.
    # Uses launchctl kickstart for Finder (launchd-mediated, preserves window
    # state) and killall for SystemUIServer/WindowManager (no launchd service).
    # Re-applies sidebar favorites after restart since Finder may restore
    # default ordering.
    # -------------------------------------------------------------------------
    relaunchDesktopServices = lib.hm.dag.entryAfter [ "configureFinderSidebar" ] ''
      ${daemonRefresh.refreshDesktopServices}

      # Finder restarts can reintroduce default favorites ordering.
      # Re-apply managed favorites to keep deterministic output.
      MYSIDES_BIN="${pkgs.mysides}/bin/mysides"
      if [ -x "$MYSIDES_BIN" ]; then
        ${finderSidebar.finderSidebarRebuildBestEffortShell}
      fi
    '';

    # -------------------------------------------------------------------------
    # verifyArchivingStack
    # Health check for archiving tools: verifies 7z CLI, Keka app registration,
    # and archive handler associations are functional after activation.
    # -------------------------------------------------------------------------
    verifyArchivingStack = lib.hm.dag.entryAfter [ "configureLaunchServices" "installPackages" ] ''
      # Verify 7z CLI is available and functional using direct Nix store path.
      # Do not rely on PATH lookup since Home Manager activation runs in a minimal
      # shell that may not have nix-darwin system package paths available yet.
      seven_z_exe="${pkgs.p7zip}/bin/7z"
      if [ ! -x "$seven_z_exe" ]; then
        echo "macos: warning — 7z binary not found at $seven_z_exe; archive extraction may fail." >&2
      elif ! "$seven_z_exe" --help >/dev/null 2>&1; then
        echo "macos: warning — 7z exists but --help failed; archive handling may be broken." >&2
      fi

      # Verify Keka application is installed and registered.
      if [ ! -d "/Applications/Keka.app" ]; then
        echo "macos: warning — Keka.app not found in /Applications; GUI archiving unavailable." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # ensureHeadlessDisplay
    # Maintains exactly one BetterDisplay virtual screen named "HeadlessDisplay"
    # and keeps it connected for clamshell remote-desktop fallback.
    #
    # BetterDisplay free-tier constraint:
    #   Runtime `set -connected=on` can fail without Pro on some builds, even
    #   for virtual screens. To avoid paid-feature dependencies, this script
    #   repairs state by recreating the virtual screen with `-connected=on`
    #   instead of relying on connection toggles.
    #
    # Steps:
    #   1. Launch BetterDisplay in the background if it is not already running.
    #   2. Query BetterDisplay identifiers for `HeadlessDisplay`.
    #   3. If there are zero/multiple instances, rebuild to one clean instance.
    #   4. If the single instance exists but is disconnected, rebuild it.
    #
    # No-op if BetterDisplay is not installed.
    # -------------------------------------------------------------------------
    ensureHeadlessDisplay = lib.hm.dag.entryAfter [ "configureNightlight" ] ''
      BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
      BD_APP="/Applications/BetterDisplay.app"
      DISPLAY_NAME="HeadlessDisplay"

      ${bdCliWrapper}

      create_headless_display() {
        # Use documented virtual-screen parameters and force connected state at
        # creation time so fallback remains available with the lid closed.
        # Source: BetterDisplay CLI virtual-screen flags.
        # https://github.com/waydabber/BetterDisplay/wiki
        "$BD_BIN" create \
          -type=VirtualScreen \
          -virtualScreenName="$DISPLAY_NAME" \
          -aspectWidth=16 \
          -aspectHeight=10 \
          -multiplierStep=160 \
          -virtualScreenHiDPI=on \
          -connected=on
      }

      discard_headless_displays() {
        # Discard by BetterDisplay tag IDs so we only touch managed virtual
        # screens and avoid affecting physical monitors.
        for tag_id in $1; do
          if ! "$BD_BIN" discard -tagID="$tag_id"; then
            echo "macos: failed to discard duplicate BetterDisplay virtual screen tagID=$tag_id." >&2
          fi
        done
      }

      if [ -f "$BD_BIN" ]; then
        if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
          /usr/bin/open -g -a "$BD_APP"
          /bin/sleep 5  # wait for the app to initialise before issuing CLI commands
        fi

        identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
        tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        tag_count="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"

        if [ "$tag_count" -ne 1 ]; then
          if [ "$tag_count" -gt 0 ]; then
            discard_headless_displays "$tag_ids"
          fi

          if ! create_headless_display; then
            echo "macos: failed to create BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
          fi
          /bin/sleep 3  # wait for the virtual display to be registered
          identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
          tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        else
          tag_id="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { print; exit }')"
          connected_state="$(_bd_cli get -tagID="$tag_id" -connected)"

          if [ "$connected_state" != "on" ]; then
            if ! "$BD_BIN" discard -tagID="$tag_id"; then
              echo "macos: failed to discard disconnected BetterDisplay virtual screen '$DISPLAY_NAME' (tagID=$tag_id)." >&2
            fi

            if ! create_headless_display; then
              echo "macos: failed to recreate BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
            fi
            /bin/sleep 3  # wait for the virtual display to be registered
            identifiers_json="$(_bd_cli get -identifiers -name="$DISPLAY_NAME")"
            tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
          fi
        fi

        connected_after="$(_bd_cli get -name="$DISPLAY_NAME" -connected)"
        if [ "$connected_after" != "on" ]; then
          echo "macos: failed to set BetterDisplay virtual screen '$DISPLAY_NAME' connected=on." >&2
        fi
      fi
    '';
  };

  # --------------------------------------------------------------------------
  # Weekly garbage collection LaunchAgent
  # Performs bounded GC on every Sunday at noon to reclaim stale VM
  # artifacts, build outputs, and tool caches that accumulate across weeks.
  launchd.agents."gc-weekly" = {
    enable = true;
    config = {
      Label = "local.gc-weekly";
      ProgramArguments = [ "${gcWeekly}" ];
      # Do not run on every agent reload during apply/bootstrap apply; weekly
      # Sunday maintenance at noon is sufficient for accumulated artifact cleanup.
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
          Weekday = 0; # Sunday (0 = Sunday, 1 = Monday, ..., 6 = Saturday)
        }
      ];
    };
  };

  # --------------------------------------------------------------------------
  # BetterDisplay heartbeat LaunchAgent (macOS-only)
  # Persistent daemon that polls the HeadlessDisplay virtual screen every
  # 30 seconds and reconnects it if BetterDisplay marks it as disconnected.
  # Uses internal sleep loop (while true; do ...; sleep 30; done) so launchd
  # KeepAlive provides crash recovery.
  #
  # Why a LaunchAgent rather than relying on ensureHeadlessDisplay alone:
  #   ensureHeadlessDisplay runs only during `home-manager switch`.  On a
  #   clamshell Mac that is left closed for hours, BetterDisplay can drop the
  #   virtual screen connection without a new activation run.  A launchd
  #   persistent agent with KeepAlive is the lightest-weight fix without
  #   requiring a Pro subscription or kernel extension.
  #
  # Output is silenced to prevent log spam from 30-second no-op loop iterations.
  # --------------------------------------------------------------------------
  launchd.agents."betterdisplay-heartbeat" = {
    enable = true;
    config = {
      Label = "local.betterdisplay-heartbeat";
      ProgramArguments = [ "${betterdisplayHeartbeat}" ];
      # Start at login and stay alive; internal loop handles the 30 s interval.
      RunAtLoad = true;
      KeepAlive = true;
      # Suppress per-iteration output to avoid filling system logs.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };

  # --------------------------------------------------------------------------
  # Daily dev-tree maintenance LaunchAgents (macOS-only)
  # `.DS_Store` cleanup and Spotlight exclusion markers only make sense on
  # macOS because both mechanisms are Finder/Spotlight-specific filesystem
  # conventions. Keep them as background launchd jobs instead of activation
  # hooks so `nix run .#apply` and bootstrap apply stay synchronous only for
  # configuration work that must happen immediately.
  # --------------------------------------------------------------------------
  launchd.agents."dev-ds-store-gc" = {
    enable = true;
    config = {
      Label = "local.dev-ds-store-gc";
      ProgramArguments = [ "${devDsStoreGc}" ];
      # Do not run on every agent reload during apply/bootstrap apply; daily
      # noon maintenance is sufficient for repository hygiene.
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  launchd.agents."dev-spotlight-exclusions" = {
    enable = true;
    config = {
      Label = "local.dev-spotlight-exclusions";
      ProgramArguments = [ "${devSpotlightExclusions}" ];
      # Do not run on every agent reload during apply/bootstrap apply; daily
      # noon maintenance is sufficient for dev-tree indexing hygiene.
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  # --------------------------------------------------------------------------
  # nix-index rebuild LaunchAgent
  # Keeps the nix-index file database current so pay-respects can suggest
  # `nix profile install` commands when an unknown command is typed.
  #
  # Why a LaunchAgent rather than a synchronous activation step:
  #   A full nix-index build takes several minutes.  Running it inline during
  #   `home-manager switch` would block the activation chain on every apply.
  #   A launchd agent runs the build asynchronously after login, with a
  #   freshness guard that makes agent reloads during apply a fast no-op.
  #
  # Output is suppressed because nix-index emits verbose per-channel progress
  # on stdout even for successful builds, which would fill the system log.
  # This suppression is intentional: failure is benign (stale DB means
  # pay-respects falls back to not suggesting packages), and the agent retries
  # on the next daily run or load.  Check exit status with:
  #   launchctl list | grep nix-index-update
  # --------------------------------------------------------------------------
  launchd.agents."nix-index-update" = {
    enable = true;
    config = {
      Label = "local.nix-index-update";
      ProgramArguments = [ "${nixIndexUpdate}" ];
      # Run once at load so a freshly provisioned machine or a machine whose
      # DB is absent or stale gets an immediate rebuild rather than waiting
      # for the next daily calendar window.
      RunAtLoad = true;
      # Daily 12:00 rebuild keeps the index fresh without waiting a full week
      # after package additions or nixpkgs updates.
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
      # Suppress per-build output to avoid filling system logs.  See above.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };

  # --------------------------------------------------------------------------
  # iCloud exclusion LaunchAgent (macOS-only)
  # Runs the iCloud directory exclusion logic hourly so that newly created
  # build/cache directories inside iCloud-managed trees are marked with
  # com.apple.fileprovider.ignore#P without waiting for the next home-manager
  # switch.  configureICloudExclusions handles the immediate first-run case;
  # this agent provides drift correction between activations.
  # RunAtLoad = false because the activation hook already runs on every apply.
  # --------------------------------------------------------------------------
  launchd.agents."icloud-exclusions" = {
    enable = true;
    config = {
      Label = "local.icloud-exclusions";
      ProgramArguments = [ "${icloudExclusionsScript}" ];
      # Do not run on every agent reload during apply/bootstrap apply; the
      # activation hook (configureICloudExclusions) runs synchronously during
      # apply and covers the immediate case.  The hourly timer handles drift
      # correction for directories created between activations.
      RunAtLoad = false;
      StartInterval = 3600;
    };
  };

  # --------------------------------------------------------------------------
  # User-level service watchdog LaunchAgent (macOS-only)
  # Persistent daemon that checks user-scope nucleus services every 5 minutes
  # with an internal 300s sleep loop.  Runs as the logged-in user so it can
  # reach ~/Library/LaunchAgents/ to check nucleus-managed user-scope launchd
  # services.  Kept in home-manager so root-launched activation does not trigger
  # macOS warnings about root managing user-scope agents.
  # --------------------------------------------------------------------------
  launchd.agents."service-watchdog-user" = {
    enable = true;
    config = {
      Label = "local.service-watchdog-user";
      ProgramArguments = [
        "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog"
        "--domain"
        "user"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/nucleus/service-watchdog/stdout.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/nucleus/service-watchdog/stderr.log";
      EnvironmentVariables = {
        NUCLEUS_SERVICES_JSON = builtins.path {
          path = ./services.json;
          name = "nucleus-services-json-user";
        };
        NUCLEUS_REPO_ROOT = builtins.getEnv "NUCLEUS_REPO_ROOT";
      };
    };
  };

  # Verify ALL home-manager-managed launchd agents are registered with launchd
  # after setupLaunchAgents runs.  On macOS 26, launchctl bootstrap can
  # spuriously return "Bootstrap failed: 5: Input/output error" — HM detects
  # this but never retries, and subsequent activations skip unchanged agents.
  home.activation.ensureLaunchAgentsLoaded = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    _gui_domain="gui/$(id -u)"
    _gen_launchagents="$newGenPath/LaunchAgents"

    if [ ! -d "$_gen_launchagents" ]; then
      verboseEcho "No LaunchAgents directory in new generation — nothing to verify"
      exit 0
    fi

    for _plist in "$_gen_launchagents"/*.plist; do
      [ -f "$_plist" ] || continue
      _label="''${_plist##*/}"
      _label="''${_label%.plist}"

      if /bin/launchctl print "$_gui_domain/$_label" >/dev/null 2>&1; then
        verboseEcho "Agent '$_label' is registered with launchd"
        continue
      fi

      warnEcho "Agent '$_gui_domain/$_label' is NOT registered — bootstrapping..."

      /bin/launchctl bootout "$_gui_domain/$_label" 2>/dev/null || true  # undoc-supp: agent may not be registered (that's why we're here), bootout expected to fail
      sleep 1

      if /bin/launchctl bootstrap "$_gui_domain" "$_plist"; then
        /bin/launchctl kickstart -p "$_gui_domain/$_label"
        verboseEcho "Agent '$_label' successfully bootstrapped and kickstarted"
      else
        warnEcho "Agent '$_label' bootstrap failed — will be picked up at next login"
      fi
    done
  '';

  # --------------------------------------------------------------------------
  # guiEnvActivationPathAndRepoRoot
  # Sets PATH (secondary mechanism) and NUCLEUS_REPO_ROOT from the activation
  # environment.  Runs after setupLaunchAgents so the gui-env agent is loaded
  # first.
  #
  # PATH PROPAGATION (dual mechanism):
  # - Primary (LaunchServices .app bundles): launchctl config system path
  #   in MacBook/activation.nix. Reboot required on first set.
  # - Secondary (launchd-direct, XPC services, non-LaunchServices): this
  #   launchctl setenv call below. Provides immediate coverage until reboot.
  # --------------------------------------------------------------------------
  home.activation.guiEnvActivationPathAndRepoRoot = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    # Propagate NUCLEUS_REPO_ROOT to GUI domain.  Captured at build time from
    # apply.sh; activation reloads it for freshness on every apply.
    if [ -n "''${NUCLEUS_REPO_ROOT:-}" ]; then
      /bin/launchctl setenv NUCLEUS_REPO_ROOT "$NUCLEUS_REPO_ROOT"
    fi

    # Propagate managed PATH to GUI domain (secondary).  Reads the current GUI
    # domain PATH at runtime (with fallback to shell PATH), strips stale managed
    # entries, then prepends + appends managed dirs.
    __nucleus_prepend="${managedPaths.toLaunchctlPrependPath}"
    __nucleus_append="${managedPaths.toLaunchctlAppendPath}"
    # Build the managed-dir LOOKUP SET for stripping stale entries.
    # This includes BOTH prepend and append dirs so that any future append
    # entries are also stripped on re-apply.  This is NOT a PATH ordering
    # — it is a dedup membership set (order irrelevant).
    __nucleus_managed_set="${mkManagedDedupSet config.home.homeDirectory}"

    CURRENT_PATH="$(/bin/launchctl getenv PATH 2>/dev/null || true)"  # undoc-supp: launchctl may not be available (early boot, non-GUI session); fall back to $PATH
    if [ -z "$CURRENT_PATH" ]; then
      CURRENT_PATH="$PATH"
    fi

    __nucleus_cleaned=""
    old_IFS="$IFS"
    IFS=:
    for __component in $CURRENT_PATH; do
      case ":''${__nucleus_managed_set}:" in
        *":''${__component}:"*) ;;
        *) __nucleus_cleaned="''${__nucleus_cleaned}:''${__component}" ;;
      esac
    done
    IFS="$old_IFS"

    if [ -n "$__nucleus_cleaned" ]; then
      /bin/launchctl setenv PATH "''${__nucleus_prepend}:''${__nucleus_cleaned}:''${__nucleus_append}"
    else
      /bin/launchctl setenv PATH "''${__nucleus_prepend}:''${__nucleus_append}"
    fi
  '';

  # --------------------------------------------------------------------------
  # GUI environment variable propagation LaunchAgent (macOS-only)
  # macOS maintains separate shell (user/<uid>/) and GUI (gui/<uid>/) launchd
  # domains.  Shell sessionVariables set via home.sessionVariables never cross
  # into the GUI domain.  This agent calls launchctl setenv for every variable
  # that GUI applications (Obsidian, VS Code, oterm, etc.) need.
  #
  # PATH PROPAGATION (dual mechanism):
  # - Primary (LaunchServices .app bundles): launchctl config system path
  #   in MacBook/activation.nix. This writes to the persistent system config
  #   plist (/private/var/db/com.apple.xpc.launchd/config/system.plist).
  #   Reboot required on first set. Settings persist across reboots.
  # - Secondary (launchd-direct, XPC services, non-LaunchServices): the
  #   launchctl setenv call below in guiEnvAgent, which re-applies PATH to
  #   the GUI domain on a 300 s interval. Also see
  #   guiEnvActivationPathAndRepoRoot which does the same during activation.
  #
  # The var list for non-PATH vars is generated from the centralized catalog
  # — see src/modules/lib/env-catalog.nix (macOSAllVars).  All vars with a macOS
  # value (both user and non-user) are included — safe because macOS launchd
  # GUI domains are per-user.
  #
  # The script runs in a persistent daemon loop (300 s interval) so env vars
  # are periodically refreshed, covering apps launched later and surviving
  # transient launchd domain resets.  Crash recovery is handled by KeepAlive.
  # --------------------------------------------------------------------------
  launchd.agents."gui-env" = {
    enable = true;
    config = {
      Label = "local.gui-env";
      ProgramArguments = [ "${guiEnvAgent}" ];
      # Start at login and stay alive; internal loop handles the 300 s interval.
      RunAtLoad = true;
      KeepAlive = true;
    };
  };
}
