# modules/agents.nix — Declarative ~/.agents directory layout for all POSIX hosts.
#
# Creates ~/.agents/ as a real directory, then creates a per-entry symlink inside
# it for every top-level entry in src/modules/configs/agents/ except skills/.
# skills/ is excluded here because it is managed by agentsSkills (below) and may
# contain downloaded content that must not be committed (fetched / ClawHub).
#
# The per-subdir layout creates ~/.agents as a real directory with per-entry
# symlinks. This allows ClawHub to write fetched skill downloads into
# ~/.agents/skills/ without those writes entering the tracked repo tree.
#
# Activation reads the repo root from:
#   1. $NUCLEUS_REPO  (set by apply.sh before the rebuild call)
#   2. ~/.config/nucleus/repo-root  (written by apply.sh, survives the sudo boundary)
# Both paths mirror the pattern used by vscodeSymlinks in editors.nix.
#
# agentsSkills (below) manages ~/.agents/skills/ independently.
{ lib, ... }:
{
  home.activation = {
    # -------------------------------------------------------------------------
    # agentsSymlink
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in src/modules/configs/agents/ except
    # skills/ (which is managed by agentsSkills so fetched ClawHub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    # -------------------------------------------------------------------------
    agentsSymlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      # Resolve the repo root so the activation can construct an absolute path
      # to src/modules/configs/agents/ regardless of where the repo is checked
      # out.  $NUCLEUS_REPO is set by apply.sh; the file fallback survives the
      # sudo boundary that darwin-rebuild / nixos-rebuild cross.
      _as_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _as_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_as_repo_root_file" ]; then
        _as_repo_root="$(cat "$_as_repo_root_file")"
      else
        echo "agents-config: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _as_agents_source="$_as_repo_root/src/modules/configs/agents"
      if [ ! -d "$_as_agents_source" ]; then
        echo "agents-config: agents config dir not found: $_as_agents_source" >&2
        exit 1
      fi

      _as_agents_dir="$HOME/.agents"

      # Ensure ~/.agents exists as a real (writable) directory.
      if [ ! -d "$_as_agents_dir" ]; then
        mkdir "$_as_agents_dir"
        echo "agents-config: created $HOME/.agents"
      elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
        # Unexpected non-directory file: fail fast.
        echo "agents-config: $HOME/.agents exists but is not a directory — remove it and re-run apply." >&2
        exit 1
      fi

      # Remove stale per-subdir symlinks: any symlink in ~/.agents/ that once
      # pointed into _as_agents_source/ but whose source entry no longer exists.
      # This keeps ~/.agents/ free of dangling links after source entries are
      # removed from the repo.  skills/ is skipped — agentsSkills owns it.
      _as_stale_list="$(mktemp)"
      find "$_as_agents_dir" -mindepth 1 -maxdepth 1 -type l > "$_as_stale_list"
      while IFS= read -r _as_candidate; do
        _as_cname="$(basename "$_as_candidate")"
        [ "$_as_cname" = "skills" ] && continue
        _as_ctarget="$(readlink "$_as_candidate")"
        case "$_as_ctarget" in
          "$_as_agents_source"/*)
            # Managed per-subdir symlink: remove if its source no longer exists.
            if [ ! -e "$_as_ctarget" ] && [ ! -L "$_as_ctarget" ]; then
              rm "$_as_candidate"
              echo "agents-config: removed stale link for $_as_cname (source removed)"
            fi
            ;;
        esac
      done < "$_as_stale_list"
      rm -f "$_as_stale_list"

      # Create or update per-entry symlinks for every top-level source entry
      # except skills/ (managed independently by agentsSkills).
      _as_source_list="$(mktemp)"
      find "$_as_agents_source" -mindepth 1 -maxdepth 1 > "$_as_source_list"
      while IFS= read -r _as_entry; do
        _as_name="$(basename "$_as_entry")"
        # skills/ is managed by agentsSkills; skip it here to avoid conflicts
        # with the real directory that agentsSkills creates for fetched downloads.
        [ "$_as_name" = "skills" ] && continue
        _as_link="$_as_agents_dir/$_as_name"
        if [ -L "$_as_link" ]; then
          if [ "$(readlink "$_as_link")" = "$_as_entry" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target (e.g. leftover from a previous checkout path): replace.
          rm "$_as_link"
          ln -s "$_as_entry" "$_as_link"
          echo "agents-config: updated $HOME/.agents/$_as_name -> $_as_entry"
        elif [ -e "$_as_link" ]; then
          # Real file or directory: fail fast to prevent silent data loss.
          echo "agents-config: $HOME/.agents/$_as_name is not a managed symlink — merge any wanted content into $_as_entry and remove it, then re-run apply." >&2
          exit 1
        else
          ln -s "$_as_entry" "$_as_link"
          echo "agents-config: linked $HOME/.agents/$_as_name -> $_as_entry"
        fi
      done < "$_as_source_list"
      rm -f "$_as_source_list"
    '';

    # -------------------------------------------------------------------------
    # agentsSkills
    # Creates ~/.agents/skills/ as a real (writable) directory, then creates a
    # per-skill symlink inside it for every skill subdirectory committed to
    # src/modules/configs/agents/skills/ (bundled / AGPL-compatible skills).
    #
    # Fetched skills (non-AGPL / ClawHub-managed) are downloaded directly into
    # ~/.agents/skills/<name>/ by the post-apply sync step in apply.sh; they
    # are never committed to the repo and are not managed here.
    #
    # The skills/ tree is a real directory — not a symlink — so that:
    #   1. Bundled per-skill symlinks can coexist with fetched real dirs.
    #   2. ClawHub can write into ~/.agents/skills/ without the writes landing
    #      inside the tracked repo tree (which would happen with a whole-dir
    #      symlink back to src/modules/configs/agents/skills/).
    #
    # Conflict safety: if a committed skill name collides with an existing real
    # directory in ~/.agents/skills/ (e.g. a fetched download), the activation
    # fails fast rather than silently overwriting the downloaded content.
    # -------------------------------------------------------------------------
    agentsSkills = lib.hm.dag.entryAfter [ "agentsSymlink" ] ''
      set -eu

      # Resolve the repo root (same mechanism as agentsSymlink above).
      _ask_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _ask_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_ask_repo_root_file" ]; then
        _ask_repo_root="$(cat "$_ask_repo_root_file")"
      else
        echo "agents-skills: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _ask_skills_source="$_ask_repo_root/src/modules/configs/agents/skills"
      if [ ! -d "$_ask_skills_source" ]; then
        echo "agents-skills: skills source dir not found: $_ask_skills_source" >&2
        exit 1
      fi

      _ask_skills_dir="$HOME/.agents/skills"

      # Ensure ~/.agents/skills/ exists as a real directory so fetched ClawHub
      # downloads can be written here without entering the tracked repo tree.
      if [ ! -d "$_ask_skills_dir" ]; then
        mkdir -p "$_ask_skills_dir"
        echo "agents-skills: created $HOME/.agents/skills"
      fi

      # Remove stale per-skill symlinks: skill dirs that once existed in the
      # source but have since been removed from the repo.
      _ask_stale_list="$(mktemp)"
      find "$_ask_skills_dir" -mindepth 1 -maxdepth 1 -type l > "$_ask_stale_list"
      while IFS= read -r _ask_candidate; do
        _ask_cname="$(basename "$_ask_candidate")"
        _ask_ctarget="$(readlink "$_ask_candidate")"
        case "$_ask_ctarget" in
          "$_ask_skills_source"/*)
            # Managed per-skill symlink: remove if its source no longer exists.
            if [ ! -e "$_ask_ctarget" ] && [ ! -L "$_ask_ctarget" ]; then
              rm "$_ask_candidate"
              echo "agents-skills: removed stale skill link for $_ask_cname (source removed)"
            fi
            ;;
        esac
      done < "$_ask_stale_list"
      rm -f "$_ask_stale_list"

      # Create or update per-skill symlinks for every subdirectory committed to
      # src/modules/configs/agents/skills/.  Non-directory entries (.gitkeep etc.)
      # are skipped; only skill directories are linked.
      _ask_source_list="$(mktemp)"
      find "$_ask_skills_source" -mindepth 1 -maxdepth 1 -type d > "$_ask_source_list"
      while IFS= read -r _ask_skill_dir; do
        _ask_skill_name="$(basename "$_ask_skill_dir")"
        _ask_link="$_ask_skills_dir/$_ask_skill_name"
        if [ -L "$_ask_link" ]; then
          if [ "$(readlink "$_ask_link")" = "$_ask_skill_dir" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target: replace symlink.
          rm "$_ask_link"
          ln -s "$_ask_skill_dir" "$_ask_link"
          echo "agents-skills: updated $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        elif [ -d "$_ask_link" ]; then
          # Real directory in place of a committed skill — could be a fetched
          # download with the same name, or user data.  Fail fast to prevent
          # silent overwrites; the operator must resolve the conflict manually.
          echo "agents-skills: $HOME/.agents/skills/$_ask_skill_name is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." >&2
          exit 1
        else
          ln -s "$_ask_skill_dir" "$_ask_link"
          echo "agents-skills: linked $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        fi
      done < "$_ask_source_list"
      rm -f "$_ask_source_list"
    '';

    # -------------------------------------------------------------------------
    # installBunPackages
    # Idempotently converges the declarative bun global package set.
    #
    # Maintains a managed set of JS CLI tools installed via `bun install -g`.
    # On each apply it compares the desired list against a per-user manifest at
    # ~/.config/nucleus/bun-packages.json, installs additions, and removes
    # deletions.
    #
    # Only packages absent from nixpkgs and cargo-binstall are managed here
    # (install preference: nixpkgs > cargo binstall > bun).
    #
    # Currently managed:
    #   clawhub — fetched skill install vehicle; absent from nixpkgs and
    #             cargo-binstall; bun is the only viable install tier.
    # -------------------------------------------------------------------------
    installBunPackages = lib.hm.dag.entryAfter [ "agentsSkills" ] ''
      set -eu

      # Prepend ~/.bun/bin so binaries installed by previous apply runs and
      # by this activation are discoverable in subsequent activation steps
      # without spawning a new shell session.  bun install -g places binaries
      # here by default (BUN_INSTALL_BIN defaults to ~/.bun).
      if [ -d "$HOME/.bun/bin" ]; then
        PATH="$HOME/.bun/bin:$PATH"
        export PATH
      fi

      # Also prepend the nix profile bin directory, Home Manager profile bin
      # directory, and directly probe the nix store for common package bins.
      # After linkGeneration the profile symlinks exist, but the activation
      # shell's PATH may not include them.
      for _dir in \
        "$HOME/.local/state/nix/profiles/profile/bin" \
        "$HOME/.nix-profile/bin" \
        "$HOME/.local/state/home-manager/profile/bin" \
        "$HOME/.local/home-manager/profile/bin"; do
        if [ -x "$_dir/bun" ]; then
          PATH="$_dir:$PATH"
          export PATH
          break
        fi
      done

      # If bun is still not found, search the nix store for any bun binary
      # and add its parent directory to PATH.
      if ! command -v bun >/dev/null 2>&1; then
        _bun_store_path="$(find /nix/store -name 'bun' -type f 2>/dev/null | head -1)"
        if [ -n "$_bun_store_path" ] && [ -x "$_bun_store_path" ]; then
          _bun_store_dir="$(dirname "$_bun_store_path")"
          PATH="$_bun_store_dir:$PATH"
          export PATH
        fi
      fi

      # bun is provided by pkgs.bun in core.nix (baseSharedPackages).  Verify
      # bun is now on PATH after the profile directory probes above.  Fail fast
      # if bun remains absent so the operator knows a full apply is needed.
      if ! command -v bun >/dev/null 2>&1; then
        echo "bun: bun not found in PATH; cannot install bun global packages" >&2
        exit 1
      fi

      # Declarative desired-state list.  One package per line.
      # Add a package name here to install it; remove it to trigger uninstall
      # on the next apply.  Only add packages absent from nixpkgs and
      # cargo-binstall (install preference: nixpkgs > cargo binstall > bun).
      _ibp_desired="$(mktemp)"
      printf '%s\n' \
        'clawhub' \
        > "$_ibp_desired"

      _ibp_manifest="$HOME/.config/nucleus/bun-packages.json"
      _ibp_manifest_dir="$(dirname "$_ibp_manifest")"

      # Read the previously-managed package list.  An absent or malformed
      # manifest (first run) is treated as an empty set so all desired packages
      # become additions.  jq -r '.[]?' exits non-zero only on malformed JSON;
      # || true is intentional and benign: the fallback is an empty previous
      # set, which is safe (all desired packages install; nothing is removed).
      _ibp_previous="$(mktemp)"
      if [ -f "$_ibp_manifest" ]; then
        jq -r '.[]?' "$_ibp_manifest" > "$_ibp_previous" || true
      fi

      # Packages no longer desired: present in the previous manifest but absent
      # from the desired list.
      _ibp_to_remove="$(mktemp)"
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        if ! grep -qxF "$_ibp_pkg" "$_ibp_desired"; then
          printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_remove"
        fi
      done < "$_ibp_previous"

      # Desired packages whose binary is absent from ~/.bun/bin.  Binary name
      # = last path component after '/' so @scope/name becomes name (bun uses
      # the unscoped basename as the binary name).
      _ibp_to_install="$(mktemp)"
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        _ibp_bin="''${_ibp_pkg##*/}"
        if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
           [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
          printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_install"
        fi
      done < "$_ibp_desired"

      # Remove packages no longer in the desired list.
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        echo "bun: removing $_ibp_pkg"
        if ! bun remove -g "$_ibp_pkg"; then
          echo "bun: 'bun remove -g $_ibp_pkg' failed" >&2
          rm -f "$_ibp_desired" "$_ibp_previous" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
      done < "$_ibp_to_remove"

      # Install packages whose binary is absent from ~/.bun/bin.
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        echo "bun: installing $_ibp_pkg"
        if ! bun install -g "$_ibp_pkg"; then
          echo "bun: 'bun install -g $_ibp_pkg' failed" >&2
          rm -f "$_ibp_desired" "$_ibp_previous" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
        _ibp_bin="''${_ibp_pkg##*/}"
        if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
           [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
          echo "bun: $_ibp_pkg installed but binary '$_ibp_bin' not found in '$HOME/.bun/bin'" >&2
          rm -f "$_ibp_desired" "$_ibp_previous" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
        echo "bun: $_ibp_pkg installed successfully"
      done < "$_ibp_to_install"

      # Persist the current desired set as the new managed manifest.  Future
      # applies read this to compute removals when a package is dropped from
      # the desired list above.
      if [ ! -d "$_ibp_manifest_dir" ]; then
        mkdir -p "$_ibp_manifest_dir"
      fi
      jq -Rn '[inputs | select(length > 0)]' "$_ibp_desired" > "$_ibp_manifest"

      rm -f "$_ibp_desired" "$_ibp_previous" "$_ibp_to_remove" "$_ibp_to_install"
    '';

    # -------------------------------------------------------------------------
    # syncClawHubSkills
    # Converges fetched skills (non-AGPL-compatible, downloaded at apply time
    # via ClawHub) with the declarative manifest in
    # src/modules/configs/agents/clawhub-skills.json.
    #
    # Why after installBunPackages: requires the ClawHub CLI, which is
    # installed by installBunPackages.  Ordering ensures ClawHub is present
    # before this step tries to invoke it.
    #
    # Why best-effort: the system configuration applied successfully.  Skill
    # sync is additive; a missing skill does not break any declared system
    # state.  Warn and continue so displayHostManualInstructions is reached.
    # -------------------------------------------------------------------------
    syncClawHubSkills = lib.hm.dag.entryAfter [ "installBunPackages" ] ''
      set -eu

      _scs_skip_sync=false

      # Prepend ~/.bun/bin so the ClawHub binary installed by installBunPackages
      # is on PATH for this activation step.
      if [ -d "$HOME/.bun/bin" ]; then
        PATH="$HOME/.bun/bin:$PATH"
        export PATH
      fi

      # Resolve the repo root (same mechanism as agentsSymlink and agentsSkills).
      _scs_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _scs_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_scs_repo_root_file" ]; then
        _scs_repo_root="$(cat "$_scs_repo_root_file")"
      else
        echo "clawhub: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      # Path to the declarative fetched skill manifest.  Slugs listed here are
      # downloaded by ClawHub; slugs absent from the manifest are cleaned up
      # from ~/.agents/skills/ when their .clawhub/origin.json marker is
      # present.
      _scs_manifest="$_scs_repo_root/src/modules/configs/agents/clawhub-skills.json"
      if [ ! -f "$_scs_manifest" ]; then
        echo "clawhub: manifest not found at $_scs_manifest; skipping fetched skill sync"
        _scs_skip_sync=true
      fi

      # Parse skill slugs from the manifest using jq.  jq is available via
      # home.packages in core.nix on all POSIX hosts.
      if ! command -v jq >/dev/null 2>&1; then
        echo "clawhub: jq not found in PATH; cannot parse fetched-skill manifest" >&2
        exit 1
      fi

      _scs_slugs_file="$(mktemp)"
      if [ "$_scs_skip_sync" = false ]; then
        jq -r '.skills[]?' "$_scs_manifest" > "$_scs_slugs_file"

        if [ ! -s "$_scs_slugs_file" ]; then
          echo "clawhub: no fetched skills in manifest; skipping"
          _scs_skip_sync=true
        fi
      fi

      _scs_skills_dir="$HOME/.agents/skills"

      # Ensure ~/.agents/skills/ exists.  The agentsSkills activation creates
      # it during home-manager switch; this guards against running before that
      # activation has run.
      if [ ! -d "$_scs_skills_dir" ]; then
        mkdir -p "$_scs_skills_dir"
      fi

      # Probe for the ClawHub CLI.  ClawHub must be pre-installed by the
      # installBunPackages activation before this step is called; this step
      # never installs ClawHub itself.
      if [ "$_scs_skip_sync" = false ] && ! command -v clawhub >/dev/null 2>&1; then
        echo "clawhub: clawhub not found in PATH; installBunPackages must complete before fetched skill sync; skipping" >&2
        _scs_skip_sync=true
      fi

      if [ "$_scs_skip_sync" = false ]; then
        echo "clawhub: running fetched skill sync..."

        # Install or update each skill from the manifest.
        #   --workdir "$HOME/.agents" installs to $HOME/.agents/skills/<slug>/
        #                            (default --dir value is "skills")
        #   --no-input               disables interactive prompts for apply safety
        while IFS= read -r _scs_slug; do
          [ -z "$_scs_slug" ] && continue
          _scs_skill_path="$_scs_skills_dir/$_scs_slug"
          if [ -L "$_scs_skill_path" ]; then
            # A committed-skill (bundled) symlink exists with the same slug.
            # Skip to avoid overwriting the managed symlink; the slug must be
            # removed from clawhub-skills.json or the committed skill removed.
            echo "clawhub: skipping '$_scs_slug' — a committed-skill symlink exists at $_scs_skill_path" >&2
            continue
          fi
          # Unlock an existing fetched skill directory before updating so
          # ClawHub can overwrite files locked a-w on a previous install.
          if [ -d "$_scs_skill_path" ]; then
            chmod -R u+w "$_scs_skill_path"
          fi
          echo "clawhub: installing/updating fetched skill '$_scs_slug'..."
          # Best-effort: non-zero exit from ClawHub is non-fatal because the
          # system apply already succeeded and skill sync is additive.
          if clawhub install --workdir "$HOME/.agents" --no-input "$_scs_slug"; then
            # Lock installed content so files cannot be modified outside a
            # managed apply run.  The unlock above re-opens write access before
            # the next update.
            if [ -d "$_scs_skill_path" ]; then
              chmod -R a-w "$_scs_skill_path"
            fi
          else
            echo "clawhub: clawhub install failed for '$_scs_slug' (system apply succeeded)" >&2
          fi
        done < "$_scs_slugs_file"

        # Stale cleanup: remove real directories in ~/.agents/skills/ that have
        # a .clawhub/origin.json marker (written by ClawHub at install time,
        # identifying fetched downloads) but whose slug is no longer in manifest.
        # Directories without this marker (bundled symlinks or user content) are
        # never touched.
        _scs_stale_list="$(mktemp)"
        find "$_scs_skills_dir" -mindepth 1 -maxdepth 1 -type d > "$_scs_stale_list"
        while IFS= read -r _scs_candidate; do
          [ -z "$_scs_candidate" ] && continue
          _scs_name="$(basename "$_scs_candidate")"
          [ ! -f "$_scs_candidate/.clawhub/origin.json" ] && continue
          if ! grep -qxF "$_scs_name" "$_scs_slugs_file"; then
            echo "clawhub: removing stale fetched skill '$_scs_name' (removed from manifest)"
            # Unlock before removal: fetched skill trees are locked a-w after
            # install, so rm -rf needs write access restored first.
            chmod -R u+w "$_scs_candidate"
            rm -rf "$_scs_candidate"
          fi
        done < "$_scs_stale_list"
        rm -f "$_scs_stale_list"
        echo "clawhub: fetched skill sync complete"
      fi

      rm -f "$_scs_slugs_file"
    '';
  };
}
