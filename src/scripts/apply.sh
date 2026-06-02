#!/usr/bin/env sh
# src/scripts/apply.sh — Dispatch the Nix apply command for the current host.
#
# Detects the operating system and invokes the appropriate flake output:
#   Darwin  → darwin-rebuild switch  (nix-darwin; manages system + home-manager)
#   NixOS   → nixos-rebuild switch   (requires sudo; detected via /etc/NIXOS)
#   Linux   → home-manager switch    (standalone HM for plain Linux / WSL)
#
# For Darwin and NixOS, the script prompts for the sudo password once upfront
# via `sudo -v`, then maintains the sudo session with a background keepalive
# loop for the duration of the rebuild (which can take many minutes).
# Standalone Linux (plain Linux / WSL) runs home-manager without sudo and
# skips the keepalive entirely.
#
# After the main apply command succeeds, scripts/ai-sync.sh is called to
# converge locally installed Ollama models with the declarative manifest.
# Pass --skip-ai-sync to suppress the model sync step — useful in CI or on
# low-bandwidth connections where model pulls (2–20 GB each) are undesirable.
#
# Arguments:
#   --skip-ai-sync  skip the post-apply Ollama model sync step
#   --replica-sync  run the post-apply cloud replica sync step (opt-in)
#   --skip-replica-sync  skip the post-apply cloud replica sync step
#   --target-user   select the Home Manager flake profile key on standalone
#                   Linux hosts (ignored on Darwin and NixOS system rebuilds)
#
# Environment variables:
#   NUCLEUS_USERNAME — override the Home Manager profile name used on standalone
#                      Linux.  Defaults to `id -un` (the current user).  Set
#                      this when the local username differs from the key used
#                      in homeConfigurations in flake.nix.
#
# Prerequisites: Nix installed; caller's environment must allow reaching the
# nix binary.
set -eu

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
skip_ai_sync=false
skip_replica_sync=true
vm_setup=false
target_user=""
_aas_expect_target_user=false

for _arg in "$@"; do
  if [ "$_aas_expect_target_user" = true ]; then
    if [ -z "$_arg" ]; then
      printf '%s\n' "apply: --target-user requires a non-empty value" >&2
      exit 1
    fi
    target_user="$_arg"
    _aas_expect_target_user=false
    continue
  fi

  case "$_arg" in
    --skip-ai-sync)
      # Model pulls are 2–20 GB and may be undesirable in CI or on
      # low-bandwidth connections; this flag opts out of the post-apply sync.
      skip_ai_sync=true
      ;;
    --replica-sync)
      # Replica sync is slow for large trees and skipped by default after
      # apply; this flag opts in to immediate post-apply convergence.
      skip_replica_sync=false
      ;;
    --skip-replica-sync)
      # Replica sync can be time-consuming for large datasets; this flag opts
      # out of the post-apply replica convergence step.
      skip_replica_sync=true
      ;;
    --vm-setup)
      # VM setup provisions QEMU disk images and registers VMs (UTM on macOS,
      # libvirt on NixOS).  Skipped by default after apply because disk
      # pre-allocation and VM registration are large, slow, and idempotent.
      vm_setup=true
      ;;
    --target-user)
      _aas_expect_target_user=true
      ;;
    --target-user=*)
      target_user="${_arg#--target-user=}"
      if [ -z "$target_user" ]; then
        printf '%s\n' "apply: --target-user requires a non-empty value" >&2
        exit 1
      fi
      ;;
    *)
      printf '%s\n' "apply: unsupported argument '$_arg'" >&2
      exit 1
      ;;
  esac
done

if [ "$_aas_expect_target_user" = true ]; then
  printf '%s\n' "apply: --target-user requires a value" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

# Augment PATH with the user Nix profile bin directory so Nix-managed binaries
# (e.g. ssh-to-age, sops) are available when the script is invoked directly
# rather than through `nix run .#apply` (which adds them via runtimeInputs).
# The guard avoids redundant PATH modifications when already present.
_nix_profile_bin="$HOME/.nix-profile/bin"
case ":$PATH:" in
  *":$_nix_profile_bin:"*) ;;
  *)
    if [ -d "$_nix_profile_bin" ]; then
      PATH="$_nix_profile_bin:$PATH"
      export PATH
    fi
    ;;
esac
unset _nix_profile_bin

# Write the repo root to a well-known path so Home Manager activation scripts
# (particularly vscodeSymlinks in editors.nix) can locate live repo files such
# as src/modules/configs/vscode/.  Environment variables are not reliably
# propagated through the sudo sessions that darwin-rebuild and nixos-rebuild
# invoke, so a stable file path is the safe transport mechanism.
mkdir -p "$HOME/.config/nucleus"
printf '%s\n' "$REPO_ROOT" > "$HOME/.config/nucleus/repo-root"

# Keep one centralized Nix config fragment for this script so every `nix` call
# gets flake support without repeating CLI flags.
NIX_FEATURES_CONFIG="experimental-features = nix-command flakes"

merge_nix_config() {
  # Merge caller-provided NIX_CONFIG (if any) with the required flake features
  # so user-level overrides remain intact while the apply flow stays portable.
  if [ -n "${NIX_CONFIG:-}" ]; then
    printf '%s\n%s' "$NIX_CONFIG" "$NIX_FEATURES_CONFIG"
  else
    printf '%s' "$NIX_FEATURES_CONFIG"
  fi
}

run_nix() {
  # Execute nix with the merged config for non-root operations.
  # Suppress repeated dirty-tree warnings so apply logs highlight actionable
  # warnings/errors instead of repeating VCS status lines.
  NIX_CONFIG="$(merge_nix_config)" nix --option warn-dirty false "$@"
}

run_nix_as_root() {
  # Execute nix as root while injecting the merged config explicitly so sudo's
  # default environment filtering cannot drop required flake settings.
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env "NIX_CONFIG=$NIX_CONFIG_VALUE" nix --option warn-dirty false "$@"
}

ensure_prek_hooks_installed() {
  # Install repository-local Git hooks for repos that opt into prek.
  # This runs after a successful apply so the current nucleus checkout is
  # protected on the same provision pass that installed or updated the binary.
  # mkApplyApp bundles pkgs.prek in runtimeInputs so first-run `nix run .#apply`
  # can install hooks without depending on host-global PATH state.
  # WHY git rev-parse: handles .git as file (submodules, worktrees) + directory
  # (normal repos). Avoids silent failure in workspace-variant scenarios.
  # Args: $1 — absolute path to the repository root to inspect
  _ephi_repo_root="$1"
  _ephi_config_path="$_ephi_repo_root/prek.toml"

  if [ ! -f "$_ephi_config_path" ]; then
    return
  fi

  # Detect .git directory; works for normal repos, submodules, and worktrees.
  _ephi_git_dir=$(cd "$_ephi_repo_root" && git rev-parse --git-dir 2>/dev/null) || return

  # Convert relative git-dir paths to absolute (git rev-parse --git-dir may
  # return relative paths like .git or ../../../.git in nested submodules).
  case "$_ephi_git_dir" in
    /*)
      # Absolute path: use as-is
      ;;
    *)
      # Relative path: join with repo root to make absolute
      _ephi_git_dir="$_ephi_repo_root/$_ephi_git_dir"
      ;;
  esac

  _ephi_hook_dir="$_ephi_git_dir/hooks"

  # Skip noisy reinstalls when any existing hook file is already a prek-
  # generated shim.  Hook sets can vary by repository, so do not hardcode
  # specific filenames here.
  if [ -d "$_ephi_hook_dir" ]; then
    for _ephi_hook_path in "$_ephi_hook_dir"/*; do
      [ -f "$_ephi_hook_path" ] || continue
      if grep -qF '# File generated by prek' "$_ephi_hook_path"; then
        return
      fi
    done
  fi

  if ! command -v prek >/dev/null 2>&1; then
    printf '%s\n' "prek: prek binary not found; skipping hook installation for $_ephi_repo_root" >&2
    return
  fi

  printf '%s\n' "prek: installing hooks in $_ephi_repo_root"
  if ! (cd "$_ephi_repo_root" && prek install); then
    printf '%s\n' "prek: failed to install hooks in $_ephi_repo_root" >&2
    exit 1
  fi
}

start_sudo_keepalive() {
  # Prompt for the sudo password once, before build output floods the terminal.
  # sudo -v validates (and refreshes) credentials without running any
  # privileged command yet.
  sudo -v

  # Keep the sudo timestamp alive for the duration of the rebuild.
  # darwin-rebuild and nixos-rebuild switch can run for many minutes;
  # the timestamp_timeout=5 set in posix-security.nix would expire mid-build
  # and block on a password prompt buried in build output.
  #
  # SCRIPT_PID is captured before the & fork because $$ is
  # implementation-defined inside a background subshell in POSIX sh —
  # capturing it here guarantees the parent's PID is used.
  #
  # Loop: sleep first (timestamp was just refreshed by sudo -v), then check
  # the parent is still alive before touching sudo, then refresh.
  # kill -0 sends no signal; it just tests whether the PID exists.
  #
  # The compound command is redirected to /dev/null so that the background
  # subshell and its children (sleep, sudo) do not inherit this script's
  # stdout/stderr file descriptors.  Without this redirect, when the script is
  # run with stdout connected to a pipe (e.g. a CI step or a tool call), the
  # pipe reader blocks until every process holding the write end closes it.
  # In non-interactive mode a shell receiving SIGTERM exits immediately but
  # does NOT kill its foreground child (the sleep); that orphaned sleep holds
  # the write end open for up to 55 s after the main script has already exited,
  # making the caller appear hung.  In a terminal stdout is a TTY — no pipe,
  # no hang — so the problem is invisible outside automated contexts.
  # sudo -n true failures are benign (session may expire mid-build; the loop
  # simply retries on the next iteration); suppression here is intentional.
  SCRIPT_PID=$$
  {
    while true; do
      sleep 55
      kill -0 "$SCRIPT_PID" 2>/dev/null || exit
      sudo -n true
    done
  } </dev/null >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!

  # Kill the keepalive on any exit (success, error, INT, or TERM) so no
  # background job is leaked to the calling shell.
  # shellcheck disable=SC2064  # intentional: expand PID now, not at trap time
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT INT TERM
}

run_ai_sync() {
  # Call scripts/ai-sync.sh to converge locally installed Ollama models with
  # the declarative manifest after the system configuration has been applied.
  #
  # Why post-apply rather than pre-apply:
  #   Model pulls are 2–20 GB; running them before activation could block the
  #   critical configuration path.  Post-apply makes sync a best-effort step
  #   that does not gate the system coming up.
  #
  # Why best-effort (no hard failure):
  #   The system configuration applied successfully.  Model sync is additive —
  #   a missing model does not break any declared system state.  Treating a
  #   sync failure as fatal would roll back a successful system apply.
  #
  # Why resolve from REPO_ROOT rather than $SCRIPT_DIR:
  #   When running via `nix run .#apply`, $SCRIPT_DIR points into the Nix
  #   store where scripts/ai-sync.sh does not exist.  REPO_ROOT is derived
  #   from `git rev-parse --show-toplevel` and always refers to the live
  #   working tree.
  #
  # Why detect ollama from $PATH rather than adding it to runtimeInputs:
  #   ollama is a user-installed daemon managed declaratively by the AI
  #   module (src/modules/ai/default.nix and hosts/NixOS/ai.nix).  Bundling
  #   it in runtimeInputs would create a second, potentially different binary
  #   that could mismatch the running server's version.  PATH detection keeps
  #   the sync aligned with the actual runtime binary.
  if [ "$skip_ai_sync" = true ]; then
    printf '%s\n' "ai-sync: --skip-ai-sync set; skipping post-apply model sync"
    return
  fi

  _ras_script="$REPO_ROOT/scripts/ai-sync.sh"
  if [ ! -f "$_ras_script" ]; then
    printf '%s\n' "ai-sync: scripts/ai-sync.sh not found at $_ras_script; skipping model sync"
    return
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    printf '%s\n' "ai-sync: ollama not found in PATH; skipping post-apply model sync"
    return
  fi

  printf '%s\n' "ai-sync: running post-apply AI model sync..."
  if ! sh "$_ras_script"; then
    printf '%s\n' "ai-sync: ai-sync.sh exited with an error; model sync incomplete (system apply succeeded)" >&2
  fi
}

run_vm_setup() {
  # Call scripts/vm-setup.sh to provision virtual machine disk images and
  # register VMs after the system configuration has been applied.
  #
  # Why opt-in (--vm-setup required):
  #   Disk pre-allocation is slow (up to 128 GB) and only needed on the first
  #   provision of a new machine.  Subsequent applies do not re-create existing
  #   disks; the guard is in the script itself.  Still, running it on every
  #   apply would waste time for users who never need it.
  #
  # Why best-effort:
  #   A VM disk or registration error should not retroactively fail a completed
  #   system apply.
  if [ "$vm_setup" = false ]; then
    printf '%s\n' "vm-setup: --vm-setup not set; skipping post-apply VM provisioning"
    return
  fi

  _rvs_script="$REPO_ROOT/scripts/vm-setup.sh"
  if [ ! -f "$_rvs_script" ]; then
    printf '%s\n' "vm-setup: scripts/vm-setup.sh not found at $_rvs_script; skipping VM setup"
    return
  fi

  printf '%s\n' "vm-setup: running post-apply VM provisioning..."
  if ! sh "$_rvs_script"; then
    printf '%s\n' "vm-setup: vm-setup.sh exited with an error; VM setup incomplete (system apply succeeded)" >&2
  fi
}

run_gc() {
  # Call scripts/gc.sh to perform bounded garbage collection after the system
  # configuration and model/VM setup have completed.
  #
  # Why post-apply:
  #   Build outputs, caches, and stale artifacts accumulate during updates.
  #   GC after all provisioning steps ensures the cleanup pass sees the most
  #   recent set of intended resources.
  #
  # Why best-effort:
  #   The system configuration and all provisioning steps have succeeded.
  #   GC failures should not retroactively fail a completed apply.
  _rgc_script="$REPO_ROOT/scripts/gc.sh"
  if [ ! -f "$_rgc_script" ]; then
    printf '%s\n' "gc: scripts/gc.sh not found at $_rgc_script; skipping garbage collection"
    return
  fi

  printf '%s\n' "gc: running post-apply garbage collection..."
  if ! sh "$_rgc_script"; then
    printf '%s\n' "gc: gc.sh exited with an error; GC incomplete (system apply succeeded)" >&2
  fi
}

run_jellyfin_account_sync() {
  # Converge Jellyfin user accounts declared in src/modules/users.json.
  # Credentials are resolved from per-user SOPS files
  # src/secrets/users-<username>.yml via key references (usernameSecretKey /
  # passwordSecretKey), so plaintext passwords are never stored in users.json.
  #
  # Upstream Jellyfin API sources:
  # - User endpoints (/Users/AuthenticateByName, /Users/New, /Users/Password):
  #   https://raw.githubusercontent.com/jellyfin/jellyfin/0beb07c40756aca5ab6a6ba4f8494bc5147e3c2b/Jellyfin.Api/Controllers/UserController.cs
  # - Startup bootstrap endpoints (/Startup/User, /Startup/Complete):
  #   https://raw.githubusercontent.com/jellyfin/jellyfin/0beb07c40756aca5ab6a6ba4f8494bc5147e3c2b/Jellyfin.Api/Controllers/StartupController.cs

  _rjas_users_json="$REPO_ROOT/src/modules/users.json"
  if [ ! -f "$_rjas_users_json" ]; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "jellyfin: curl is not available; skipping account sync"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "jellyfin: jq is not available; skipping account sync"
    return
  fi
  if ! command -v sops >/dev/null 2>&1; then
    printf '%s\n' "jellyfin: sops is not available; skipping account sync"
    return
  fi

  _rjas_base_url="${JELLYFIN_BASE_URL:-http://127.0.0.1:8096}"
  _rjas_auth_base='MediaBrowser Client="nucleus-apply", DeviceId="posix-apply", Device="POSIX", Version="1.0.0"'

  _rjas_specs_file="$(mktemp)"
  _rjas_resolved_file="$(mktemp)"

  jq -cr '
    to_entries[]
    | . as $u
    | (($u.value.jellyfin.accounts // []) | sort_by(.id)[])
    | {
        owner: $u.key,
        id: .id,
        isAdmin: (.isAdmin // false),
        usernameSecretKey: .usernameSecretKey,
        passwordSecretKey: .passwordSecretKey
      }
  ' "$_rjas_users_json" > "$_rjas_specs_file"

  if [ ! -s "$_rjas_specs_file" ]; then
    rm -f "$_rjas_specs_file" "$_rjas_resolved_file"
    return
  fi

  while IFS= read -r _rjas_spec; do
    _rjas_owner="$(printf '%s' "$_rjas_spec" | jq -r '.owner')"
    _rjas_id="$(printf '%s' "$_rjas_spec" | jq -r '.id')"
    _rjas_is_admin_spec="$(printf '%s' "$_rjas_spec" | jq -r '.isAdmin // false')"
    _rjas_user_key="$(printf '%s' "$_rjas_spec" | jq -r '.usernameSecretKey // empty')"
    _rjas_pass_key="$(printf '%s' "$_rjas_spec" | jq -r '.passwordSecretKey // empty')"

    if [ -z "$_rjas_owner" ] || [ -z "$_rjas_user_key" ] || [ -z "$_rjas_pass_key" ]; then
      printf '%s\n' "jellyfin: invalid account declaration for id '${_rjas_id:-<unknown>}'; skipping" >&2
      continue
    fi

    _rjas_secret_file="$REPO_ROOT/src/secrets/users-${_rjas_owner}.yml"
    if [ ! -f "$_rjas_secret_file" ]; then
      printf '%s\n' "jellyfin: missing users-${_rjas_owner}.yml; skipping account declaration '${_rjas_id}'" >&2
      continue
    fi

    if ! _rjas_secret_json="$(sops --decrypt --output-type json "$_rjas_secret_file")"; then
      printf '%s\n' "jellyfin: failed to decrypt $_rjas_secret_file; skipping account declaration '${_rjas_id}'" >&2
      continue
    fi

    _rjas_username="$(printf '%s' "$_rjas_secret_json" | jq -r --arg key "$_rjas_user_key" '.[$key] // empty')"
    _rjas_password="$(printf '%s' "$_rjas_secret_json" | jq -r --arg key "$_rjas_pass_key" '.[$key] // empty')"
    if [ -z "$_rjas_username" ] || [ -z "$_rjas_password" ]; then
      printf '%s\n' "jellyfin: missing secret values for account declaration '${_rjas_id}' in users-${_rjas_owner}.yml" >&2
      continue
    fi

    jq -cn \
      --arg owner "$_rjas_owner" \
      --arg id "$_rjas_id" \
      --arg username "$_rjas_username" \
        --arg password "$_rjas_password" \
        --argjson isAdmin "$_rjas_is_admin_spec" \
        '{owner:$owner,id:$id,username:$username,password:$password,isAdmin:$isAdmin}' >> "$_rjas_resolved_file"
  done < "$_rjas_specs_file"

  rm -f "$_rjas_specs_file"
  if [ ! -s "$_rjas_resolved_file" ]; then
    rm -f "$_rjas_resolved_file"
    return
  fi

  # Probe readiness; startup can lag behind service registration after apply.
  _rjas_waited=0
  while [ "$_rjas_waited" -lt 60 ]; do
    # Expected-benign failures (connection refused during startup) are checked
    # via exit status; suppressing output keeps apply logs readable.
    if curl -fsS --max-time 5 "$_rjas_base_url/System/Info/Public" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    _rjas_waited=$((_rjas_waited + 1))
  done

  if [ "$_rjas_waited" -ge 60 ]; then
    printf '%s\n' "jellyfin: API at $_rjas_base_url is not reachable; skipping account sync"
    rm -f "$_rjas_resolved_file"
    return
  fi

  _rjas_api_request() {
    _rjar_method="$1"
    _rjar_path="$2"
    _rjar_token="$3"
    _rjar_body="$4"
    _rjar_url="$_rjas_base_url$_rjar_path"
    _rjar_auth="$_rjas_auth_base"
    if [ -n "$_rjar_token" ]; then
      _rjar_auth="$_rjar_auth, Token=$_rjar_token"
    fi

    if [ -n "$_rjar_body" ]; then
      curl -sS -X "$_rjar_method" "$_rjar_url" \
        -H "Authorization: $_rjar_auth" \
        -H "Content-Type: application/json" \
        --data "$_rjar_body" \
        -w 'HTTPSTATUS:%{http_code}'
    else
      curl -sS -X "$_rjar_method" "$_rjar_url" \
        -H "Authorization: $_rjar_auth" \
        -w 'HTTPSTATUS:%{http_code}'
    fi
  }

  _rjas_status_from_response() {
    printf '%s' "$1" | sed -n 's/.*HTTPSTATUS:\([0-9][0-9][0-9]\)$/\1/p'
  }

  _rjas_body_from_response() {
    printf '%s' "$1" | sed 's/HTTPSTATUS:[0-9][0-9][0-9]$//'
  }

  _rjas_admin_token=""
  while IFS= read -r _rjas_account; do
    _rjas_username="$(printf '%s' "$_rjas_account" | jq -r '.username')"
    _rjas_password="$(printf '%s' "$_rjas_account" | jq -r '.password')"
    _rjas_desired_admin="$(printf '%s' "$_rjas_account" | jq -r '.isAdmin // false')"

    _rjas_auth_payload="$(jq -cn --arg username "$_rjas_username" --arg password "$_rjas_password" '{Username:$username,Pw:$password}')"
    _rjas_auth_response="$(_rjas_api_request POST '/Users/AuthenticateByName' '' "$_rjas_auth_payload")"
    _rjas_auth_status="$(_rjas_status_from_response "$_rjas_auth_response")"
    if [ "$_rjas_auth_status" != "200" ]; then
      continue
    fi

    _rjas_token="$(printf '%s' "$(_rjas_body_from_response "$_rjas_auth_response")" | jq -r '.AccessToken // empty')"
    if [ -z "$_rjas_token" ]; then
      continue
    fi

    _rjas_me_response="$(_rjas_api_request GET '/Users/Me' "$_rjas_token" '')"
    _rjas_me_status="$(_rjas_status_from_response "$_rjas_me_response")"
    if [ "$_rjas_me_status" != "200" ]; then
      continue
    fi

    _rjas_is_admin="$(printf '%s' "$(_rjas_body_from_response "$_rjas_me_response")" | jq -r '.Policy.IsAdministrator // false')"
    if [ "$_rjas_is_admin" = "true" ]; then
      _rjas_admin_token="$_rjas_token"
      break
    fi
  done < "$_rjas_resolved_file"

  if [ -z "$_rjas_admin_token" ]; then
    _rjas_bootstrap_account="$(head -n 1 "$_rjas_resolved_file")"
    _rjas_bootstrap_username="$(printf '%s' "$_rjas_bootstrap_account" | jq -r '.username')"
    _rjas_bootstrap_password="$(printf '%s' "$_rjas_bootstrap_account" | jq -r '.password')"
    _rjas_startup_payload="$(jq -cn --arg name "$_rjas_bootstrap_username" --arg password "$_rjas_bootstrap_password" '{Name:$name,Password:$password}')"

    _rjas_startup_response="$(_rjas_api_request POST '/Startup/User' '' "$_rjas_startup_payload")"
    _rjas_startup_status="$(_rjas_status_from_response "$_rjas_startup_response")"
    if [ "$_rjas_startup_status" = "204" ]; then
      _rjas_complete_response="$(_rjas_api_request POST '/Startup/Complete' '' '')"
      _rjas_complete_status="$(_rjas_status_from_response "$_rjas_complete_response")"
      if [ "$_rjas_complete_status" != "204" ]; then
        printf '%s\n' "jellyfin: startup completion returned HTTP $_rjas_complete_status" >&2
      fi
    fi

    _rjas_bootstrap_auth_payload="$(jq -cn --arg username "$_rjas_bootstrap_username" --arg password "$_rjas_bootstrap_password" '{Username:$username,Pw:$password}')"
    _rjas_bootstrap_attempt=0
    while [ "$_rjas_bootstrap_attempt" -lt 15 ] && [ -z "$_rjas_admin_token" ]; do
      _rjas_bootstrap_auth_response="$(_rjas_api_request POST '/Users/AuthenticateByName' '' "$_rjas_bootstrap_auth_payload")"
      _rjas_bootstrap_auth_status="$(_rjas_status_from_response "$_rjas_bootstrap_auth_response")"
      if [ "$_rjas_bootstrap_auth_status" = "200" ]; then
        _rjas_bootstrap_token="$(printf '%s' "$(_rjas_body_from_response "$_rjas_bootstrap_auth_response")" | jq -r '.AccessToken // empty')"
        if [ -n "$_rjas_bootstrap_token" ]; then
          _rjas_bootstrap_me_response="$(_rjas_api_request GET '/Users/Me' "$_rjas_bootstrap_token" '')"
          _rjas_bootstrap_me_status="$(_rjas_status_from_response "$_rjas_bootstrap_me_response")"
          if [ "$_rjas_bootstrap_me_status" = "200" ]; then
            _rjas_bootstrap_is_admin="$(printf '%s' "$(_rjas_body_from_response "$_rjas_bootstrap_me_response")" | jq -r '.Policy.IsAdministrator // false')"
            if [ "$_rjas_bootstrap_is_admin" = "true" ]; then
              _rjas_admin_token="$_rjas_bootstrap_token"
              break
            fi
          fi
        fi
      fi
      sleep 1
      _rjas_bootstrap_attempt=$((_rjas_bootstrap_attempt + 1))
    done
  fi

  if [ -z "$_rjas_admin_token" ]; then
    printf '%s\n' "jellyfin: no elevated account credentials available; skipping account sync"
    rm -f "$_rjas_resolved_file"
    return
  fi

  while IFS= read -r _rjas_account; do
    _rjas_username="$(printf '%s' "$_rjas_account" | jq -r '.username')"
    _rjas_password="$(printf '%s' "$_rjas_account" | jq -r '.password')"

    _rjas_users_response="$(_rjas_api_request GET '/Users' "$_rjas_admin_token" '')"
    _rjas_users_status="$(_rjas_status_from_response "$_rjas_users_response")"
    if [ "$_rjas_users_status" != "200" ]; then
      printf '%s\n' "jellyfin: failed to list users (HTTP $_rjas_users_status); stopping account sync" >&2
      break
    fi
    _rjas_users_body="$(_rjas_body_from_response "$_rjas_users_response")"

    _rjas_user_id="$(printf '%s' "$_rjas_users_body" | jq -r --arg username "$_rjas_username" 'map(select(.Name == $username)) | .[0].Id // empty')"

    if [ -z "$_rjas_user_id" ]; then
      _rjas_create_payload="$(jq -cn --arg name "$_rjas_username" --arg password "$_rjas_password" '{Name:$name,Password:$password}')"
      _rjas_create_response="$(_rjas_api_request POST '/Users/New' "$_rjas_admin_token" "$_rjas_create_payload")"
      _rjas_create_status="$(_rjas_status_from_response "$_rjas_create_response")"
      if [ "$_rjas_create_status" = "200" ]; then
        printf '%s\n' "jellyfin: created account '$_rjas_username'"
        _rjas_user_id="$(printf '%s' "$(_rjas_body_from_response "$_rjas_create_response")" | jq -r '.Id // empty')"
        if [ -z "$_rjas_user_id" ]; then
          printf '%s\n' "jellyfin: created account '$_rjas_username' but could not resolve user id for policy sync" >&2
          continue
        fi
      else
        printf '%s\n' "jellyfin: failed to create account '$_rjas_username' (HTTP $_rjas_create_status)" >&2
        continue
      fi
    fi

    _rjas_user_detail_response="$(_rjas_api_request GET "/Users/${_rjas_user_id}" "$_rjas_admin_token" '')"
    _rjas_user_detail_status="$(_rjas_status_from_response "$_rjas_user_detail_response")"
    if [ "$_rjas_user_detail_status" != "200" ]; then
      printf '%s\n' "jellyfin: failed to query account details for '$_rjas_username' (HTTP $_rjas_user_detail_status)" >&2
      continue
    fi

    _rjas_user_policy_json="$(printf '%s' "$(_rjas_body_from_response "$_rjas_user_detail_response")" | jq -c '.Policy // empty')"
    if [ -z "$_rjas_user_policy_json" ]; then
      printf '%s\n' "jellyfin: missing policy payload for account '$_rjas_username'; skipping admin policy sync" >&2
      continue
    fi

    _rjas_current_admin="$(printf '%s' "$_rjas_user_policy_json" | jq -r '.IsAdministrator // false')"
    if [ "$_rjas_current_admin" != "$_rjas_desired_admin" ]; then
      _rjas_updated_policy="$(printf '%s' "$_rjas_user_policy_json" | jq -c --argjson isAdmin "$_rjas_desired_admin" '.IsAdministrator = $isAdmin')"
      _rjas_policy_update_response="$(_rjas_api_request POST "/Users/${_rjas_user_id}/Policy" "$_rjas_admin_token" "$_rjas_updated_policy")"
      _rjas_policy_update_status="$(_rjas_status_from_response "$_rjas_policy_update_response")"
      if [ "$_rjas_policy_update_status" = "204" ]; then
        printf '%s\n' "jellyfin: updated admin policy for account '$_rjas_username' to $_rjas_desired_admin"
      else
        printf '%s\n' "jellyfin: failed to update admin policy for account '$_rjas_username' (HTTP $_rjas_policy_update_status)" >&2
      fi
    fi

    _rjas_check_payload="$(jq -cn --arg username "$_rjas_username" --arg password "$_rjas_password" '{Username:$username,Pw:$password}')"
    _rjas_check_response="$(_rjas_api_request POST '/Users/AuthenticateByName' '' "$_rjas_check_payload")"
    _rjas_check_status="$(_rjas_status_from_response "$_rjas_check_response")"
    if [ "$_rjas_check_status" = "200" ]; then
      continue
    fi

    _rjas_password_payload="$(jq -cn --arg password "$_rjas_password" '{ResetPassword:false,NewPw:$password}')"
    _rjas_password_response="$(_rjas_api_request POST "/Users/Password?userId=${_rjas_user_id}" "$_rjas_admin_token" "$_rjas_password_payload")"
    _rjas_password_status="$(_rjas_status_from_response "$_rjas_password_response")"
    if [ "$_rjas_password_status" = "204" ]; then
      printf '%s\n' "jellyfin: updated password for account '$_rjas_username'"
    else
      printf '%s\n' "jellyfin: failed to update password for account '$_rjas_username' (HTTP $_rjas_password_status)" >&2
    fi
  done < "$_rjas_resolved_file"

  rm -f "$_rjas_resolved_file"
}

run_jellyfin_library_sync() {
  # Converge Jellyfin library folders declared in src/modules/users.json.
  # Each user can declare jellyfin.libraries (default empty).  Libraries are
  # merged by name (first writer wins).  ~/ paths are resolved against each
  # user's homeDirectory at sync time.
  #
  # Idempotent: missing libraries created, existing ones updated, undecorated
  # libraries left untouched.  Reuses the api-request helpers defined by
  # run_jellyfin_account_sync.

  _rjls_users_json="$REPO_ROOT/src/modules/users.json"
  if [ ! -f "$_rjls_users_json" ]; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "jellyfin/library: curl is not available; skipping library sync"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "jellyfin/library: jq is not available; skipping library sync"
    return
  fi
  if ! command -v sops >/dev/null 2>&1; then
    printf '%s\n' "jellyfin/library: sops is not available; skipping library sync"
    return
  fi

  # Build library specs and collect auth credentials from all users.
  _rjls_specs_file="$(mktemp)"
  _rjls_creds_file="$(mktemp)"

  jq -cr '
    to_entries[]
    | . as $u
    | (($u.value.jellyfin.libraries // []) | sort_by(.name)[])
    | {
        owner: $u.key,
        home: $u.value.homeDirectory,
        name: .name,
        collectionType: .collectionType,
        paths: (.paths // []),
        options: .options
      }
  ' "$_rjls_users_json" > "$_rjls_specs_file"

  # Collect auth credentials from all users with library declarations.
  while IFS= read -r _rjls_spec; do
    _rjls_owner="$(printf '%s' "$_rjls_spec" | jq -r '.owner')"
    _rjls_secret_file="$REPO_ROOT/src/secrets/users-${_rjls_owner}.yml"
    if [ ! -f "$_rjls_secret_file" ]; then
      continue
    fi

    if ! _rjls_secret_json="$(sops --decrypt --output-type json "$_rjls_secret_file")"; then
      continue
    fi

    # Look up jellyfin accounts for this user to get credentials.
    jq -cr --arg owner "$_rjls_owner" '
      .[$owner].jellyfin.accounts // [] | .[]
      | {owner: $owner} + .
    ' "$_rjls_users_json" 2>/dev/null | while IFS= read -r _rjls_account; do
      _rjls_user_key="$(printf '%s' "$_rjls_account" | jq -r '.usernameSecretKey // empty')"
      _rjls_pass_key="$(printf '%s' "$_rjls_account" | jq -r '.passwordSecretKey // empty')"
      if [ -z "$_rjls_user_key" ] || [ -z "$_rjls_pass_key" ]; then
        continue
      fi
      _rjls_username="$(printf '%s' "$_rjls_secret_json" | jq -r --arg key "$_rjls_user_key" '.[$key] // empty')"
      _rjls_password="$(printf '%s' "$_rjls_secret_json" | jq -r --arg key "$_rjls_pass_key" '.[$key] // empty')"
      if [ -z "$_rjls_username" ] || [ -z "$_rjls_password" ]; then
        continue
      fi
      printf '%s\n' "$(jq -cn --arg owner "$_rjls_owner" --arg username "$_rjls_username" --arg password "$_rjls_password" '{owner:$owner,username:$username,password:$password}')"
    done
  done < "$_rjls_specs_file" > "$_rjls_creds_file"

  if [ ! -s "$_rjls_specs_file" ]; then
    rm -f "$_rjls_specs_file" "$_rjls_creds_file"
    return
  fi

  # Resolve ~ paths against each user's homeDirectory.
  _rjls_resolved_file="$(mktemp)"
  while IFS= read -r _rjls_spec; do
    _rjls_owner="$(printf '%s' "$_rjls_spec" | jq -r '.owner')"
    _rjls_home="$(printf '%s' "$_rjls_spec" | jq -r '.home')"
    _rjls_name="$(printf '%s' "$_rjls_spec" | jq -r '.name')"
    _rjls_collection_type="$(printf '%s' "$_rjls_spec" | jq -r '.collectionType')"
    _rjls_options="$(printf '%s' "$_rjls_spec" | jq -c '.options')"

    _rjls_paths_json="$(printf '%s' "$_rjls_spec" | jq -c '.paths')"
    _rjls_resolved_paths_json="$(printf '%s' "$_rjls_paths_json" | jq -c --arg home "$_rjls_home" '
      map(if startswith("~/") then ($home + .[1:]) else . end)
    ')"

    jq -cn \
      --arg owner "$_rjls_owner" \
      --arg name "$_rjls_name" \
      --arg collectionType "$_rjls_collection_type" \
      --argjson paths "$_rjls_resolved_paths_json" \
      --argjson options "$_rjls_options" \
      '{owner:$owner,name:$name,collectionType:$collectionType,paths:$paths,options:$options}' >> "$_rjls_resolved_file"
  done < "$_rjls_specs_file"

  rm -f "$_rjls_specs_file"

  if [ ! -s "$_rjls_resolved_file" ]; then
    rm -f "$_rjls_resolved_file" "$_rjls_creds_file"
    return
  fi

  # Merge by name (first writer wins).
  _rjls_merged_file="$(mktemp)"
  _rjls_merge_input="$(mktemp)"
  while IFS= read -r _rjls_line; do printf '%s\n' "$_rjls_line"; done < "$_rjls_resolved_file" > "$_rjls_merge_input"
  jq -s '
    group_by(.name | ascii_downcase)
    | map(.[0])
    | to_entries
    | map(.value)
  ' "$_rjls_merge_input" > "$_rjls_merged_file" 2>/dev/null || cat "$_rjls_resolved_file" > "$_rjls_merged_file"
  rm -f "$_rjls_merge_input"

  rm -f "$_rjls_resolved_file"

  # Probe readiness (API may already be up from account sync, but be safe).
  _rjls_waited=0
  while [ "$_rjls_waited" -lt 60 ]; do
    if curl -fsS --max-time 5 "$_rjas_base_url/System/Info/Public" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    _rjls_waited=$((_rjls_waited + 1))
  done

  if [ "$_rjls_waited" -ge 60 ]; then
    printf '%s\n' "jellyfin/library: API at $_rjas_base_url is not reachable; skipping library sync"
    rm -f "$_rjls_merged_file" "$_rjls_creds_file"
    return
  fi

  # Acquire admin token (try each credentialed user).
  _rjls_admin_token=""
  while IFS= read -r _rjls_cred; do
    _rjls_username="$(printf '%s' "$_rjls_cred" | jq -r '.username')"
    _rjls_password="$(printf '%s' "$_rjls_cred" | jq -r '.password')"

    _rjls_auth_payload="$(jq -cn --arg username "$_rjls_username" --arg password "$_rjls_password" '{Username:$username,Pw:$password}')"
    _rjls_auth_response="$(_rjas_api_request POST '/Users/AuthenticateByName' '' "$_rjls_auth_payload")"
    _rjls_auth_status="$(_rjas_status_from_response "$_rjls_auth_response")"
    if [ "$_rjls_auth_status" != "200" ]; then
      continue
    fi

    _rjls_token="$(printf '%s' "$(_rjas_body_from_response "$_rjls_auth_response")" | jq -r '.AccessToken // empty')"
    if [ -z "$_rjls_token" ]; then
      continue
    fi

    _rjls_me_response="$(_rjas_api_request GET '/Users/Me' "$_rjls_token" '')"
    _rjls_me_status="$(_rjas_status_from_response "$_rjls_me_response")"
    if [ "$_rjls_me_status" != "200" ]; then
      continue
    fi

    _rjls_is_admin="$(printf '%s' "$(_rjas_body_from_response "$_rjls_me_response")" | jq -r '.Policy.IsAdministrator // false')"
    if [ "$_rjls_is_admin" = "true" ]; then
      _rjls_admin_token="$_rjls_token"
      break
    fi
  done < "$_rjls_creds_file"

  if [ -z "$_rjls_admin_token" ]; then
    _rjls_bootstrap_cred="$(head -n 1 "$_rjls_creds_file")"
    if [ -n "$_rjls_bootstrap_cred" ]; then
      _rjls_bootstrap_username="$(printf '%s' "$_rjls_bootstrap_cred" | jq -r '.username')"
      _rjls_bootstrap_password="$(printf '%s' "$_rjls_bootstrap_cred" | jq -r '.password')"
      _rjls_startup_payload="$(jq -cn --arg name "$_rjls_bootstrap_username" --arg password "$_rjls_bootstrap_password" '{Name:$name,Password:$password}')"
      _rjls_startup_response="$(_rjas_api_request POST '/Startup/User' '' "$_rjls_startup_payload")"
      _rjls_startup_status="$(_rjas_status_from_response "$_rjls_startup_response")"
      if [ "$_rjls_startup_status" = "204" ]; then
        _rjas_complete_response="$(_rjas_api_request POST '/Startup/Complete' '' '')"
      fi

      _rjls_bootstrap_attempt=0
      while [ "$_rjls_bootstrap_attempt" -lt 15 ] && [ -z "$_rjls_admin_token" ]; do
        _rjls_bootstrap_auth_response="$(_rjas_api_request POST '/Users/AuthenticateByName' '' "$_rjls_startup_payload")"
        _rjls_bootstrap_auth_status="$(_rjas_status_from_response "$_rjls_bootstrap_auth_response")"
        if [ "$_rjls_bootstrap_auth_status" = "200" ]; then
          _rjls_bootstrap_token="$(printf '%s' "$(_rjas_body_from_response "$_rjls_bootstrap_auth_response")" | jq -r '.AccessToken // empty')"
          if [ -n "$_rjls_bootstrap_token" ]; then
            _rjls_bootstrap_me_response="$(_rjas_api_request GET '/Users/Me' "$_rjls_bootstrap_token" '')"
            _rjls_bootstrap_is_admin="$(printf '%s' "$(_rjas_body_from_response "$_rjls_bootstrap_me_response")" | jq -r '.Policy.IsAdministrator // false')"
            if [ "$_rjls_bootstrap_is_admin" = "true" ]; then
              _rjls_admin_token="$_rjls_bootstrap_token"
              break
            fi
          fi
        fi
        sleep 1
        _rjls_bootstrap_attempt=$((_rjls_bootstrap_attempt + 1))
      done
    fi
  fi

  if [ -z "$_rjls_admin_token" ]; then
    printf '%s\n' "jellyfin/library: no elevated account credentials available; skipping library sync"
    rm -f "$_rjls_merged_file" "$_rjls_creds_file"
    return
  fi

  rm -f "$_rjls_creds_file"

  # GET /Library/VirtualFolders — list existing folders.
  _rjls_folders_response="$(_rjas_api_request GET '/Library/VirtualFolders' "$_rjls_admin_token" '')"
  _rjls_folders_status="$(_rjas_status_from_response "$_rjls_folders_response")"
  if [ "$_rjls_folders_status" != "200" ]; then
    printf '%s\n' "jellyfin/library: failed to list virtual folders (HTTP $_rjls_folders_status); skipping"
    rm -f "$_rjls_merged_file"
    return
  fi
  _rjls_folders_body="$(_rjas_body_from_response "$_rjls_folders_response")"

  # For each declared library: create if missing, update options if exists.
  _rjls_libs="$(cat "$_rjls_merged_file")"
  rm -f "$_rjls_merged_file"

  printf '%s' "$_rjls_libs" | jq -c '.[]' | while IFS= read -r _rjls_lib; do
    _rjls_name="$(printf '%s' "$_rjls_lib" | jq -r '.name')"
    _rjls_collection_type="$(printf '%s' "$_rjls_lib" | jq -r '.collectionType')"
    _rjls_paths="$(printf '%s' "$_rjls_lib" | jq -c '.paths')"
    _rjls_options="$(printf '%s' "$_rjls_lib" | jq -c '.options')"

    # Build LibraryOptions payload matching the JSON schema in users.json.
    _rjls_backdrop_limit="$(printf '%s' "$_rjls_options" | jq -r '.imageOptions.Backdrop.limit // 1')"
    _rjls_backdrop_minwidth="$(printf '%s' "$_rjls_options" | jq -r '.imageOptions.Backdrop.minWidth // 1280')"
    _rjls_logo_limit="$(printf '%s' "$_rjls_options" | jq -r '.imageOptions.Logo.limit // 1')"
    _rjls_primary_limit="$(printf '%s' "$_rjls_options" | jq -r '.imageOptions.Primary.limit // 1')"
    _rjls_image_fetchers="$(printf '%s' "$_rjls_options" | jq -c '.imageFetchers // ["Embedded Image Extractor","Screen Grabber"]')"

    _rjls_library_options="$(jq -cn \
      --argjson enabled "$(printf '%s' "$_rjls_options" | jq '.enabled // true')" \
      --argjson enableRealtimeMonitor "$(printf '%s' "$_rjls_options" | jq '.enableRealtimeMonitor // true')" \
      --argjson enableEmbeddedTitles "$(printf '%s' "$_rjls_options" | jq '.enableEmbeddedTitles // true')" \
      --argjson enableEmbeddedExtrasTitles "$(printf '%s' "$_rjls_options" | jq '.enableEmbeddedExtrasTitles // false')" \
      --arg allowEmbeddedSubtitles "$(printf '%s' "$_rjls_options" | jq -r '.allowEmbeddedSubtitles // "AllowAll"')" \
      --argjson saveLocalMetadata "$(printf '%s' "$_rjls_options" | jq '.saveLocalMetadata // false')" \
      --argjson enableChapterImageExtraction "$(printf '%s' "$_rjls_options" | jq '.enableChapterImageExtraction // true')" \
      --argjson extractChapterImagesDuringLibraryScan "$(printf '%s' "$_rjls_options" | jq '.extractChapterImagesDuringLibraryScan // false')" \
      --argjson enableTrickplayImageExtraction "$(printf '%s' "$_rjls_options" | jq '.enableTrickplayImageExtraction // true')" \
      --argjson extractTrickplayImagesDuringLibraryScan "$(printf '%s' "$_rjls_options" | jq '.extractTrickplayImagesDuringLibraryScan // false')" \
      --argjson saveTrickplayWithMedia "$(printf '%s' "$_rjls_options" | jq '.saveTrickplayWithMedia // false')" \
      --argjson imageFetchers "$_rjls_image_fetchers" \
      --argjson backdropLimit "$_rjls_backdrop_limit" \
      --argjson backdropMinWidth "$_rjls_backdrop_minwidth" \
      --argjson logoLimit "$_rjls_logo_limit" \
      --argjson primaryLimit "$_rjls_primary_limit" \
      '{
        Enabled: $enabled,
        EnableRealtimeMonitor: $enableRealtimeMonitor,
        EnableEmbeddedTitles: $enableEmbeddedTitles,
        EnableEmbeddedExtrasTitles: $enableEmbeddedExtrasTitles,
        AllowEmbeddedSubtitles: $allowEmbeddedSubtitles,
        MetadataSavers: [],
        SaveLocalMetadata: $saveLocalMetadata,
        EnableChapterImageExtraction: $enableChapterImageExtraction,
        ExtractChapterImagesDuringLibraryScan: $extractChapterImagesDuringLibraryScan,
        EnableTrickplayImageExtraction: $enableTrickplayImageExtraction,
        ExtractTrickplayImagesDuringLibraryScan: $extractTrickplayImagesDuringLibraryScan,
        SaveTrickplayWithMedia: $saveTrickplayWithMedia,
        TypeOptions: [
          {
            Type: "MusicVideo",
            ImageFetchers: $imageFetchers,
            ImageFetcherOrder: $imageFetchers,
            MetadataFetchers: [],
            ImageOptions: [
              {Type: "Backdrop", Limit: $backdropLimit, MinWidth: $backdropMinWidth},
              {Type: "Logo", Limit: $logoLimit},
              {Type: "Primary", Limit: $primaryLimit}
            ]
          }
        ]
      }')"

    # Check if this library already exists.
    _rjls_existing_item_id="$(printf '%s' "$_rjls_folders_body" | jq -r --arg name "$_rjls_name" '
      map(select(.Name == $name))
      | .[0]
      | (.ItemId // .Id // empty)
    ')"

    if [ -z "$_rjls_existing_item_id" ]; then
      # Create new library.
      _rjls_query_params="name=$(printf '%s' "$_rjls_name" | jq -sRr @uri)&collectionType=$(printf '%s' "$_rjls_collection_type" | jq -sRr @uri)"
      _rjls_paths_file="$(mktemp)"
      printf '%s' "$_rjls_paths" | jq -r '.[]' > "$_rjls_paths_file"
      while IFS= read -r _rjls_path; do
        _rjls_query_params="$_rjls_query_params&paths=$(printf '%s' "$_rjls_path" | jq -sRr @uri)"
      done < "$_rjls_paths_file"
      rm -f "$_rjls_paths_file"
      _rjls_create_response="$(_rjas_api_request POST "/Library/VirtualFolders?${_rjls_query_params}" "$_rjls_admin_token" "$_rjls_library_options")"
      _rjls_create_status="$(_rjas_status_from_response "$_rjls_create_response")"
      if [ "$_rjls_create_status" = "204" ]; then
        printf '%s\n' "jellyfin/library: created library '$_rjls_name' ($_rjls_collection_type)"
      else
        printf '%s\n' "jellyfin/library: failed to create library '$_rjls_name' (HTTP $_rjls_create_status)" >&2
      fi
    else
      # Update existing library options.
      _rjls_update_payload="$(jq -cn --arg id "$_rjls_existing_item_id" --argjson options "$_rjls_library_options" '{Id:$id,LibraryOptions:$options}')"
      _rjls_update_response="$(_rjas_api_request POST '/Library/VirtualFolders/LibraryOptions' "$_rjls_admin_token" "$_rjls_update_payload")"
      _rjls_update_status="$(_rjas_status_from_response "$_rjls_update_response")"
      if [ "$_rjls_update_status" = "204" ]; then
        printf '%s\n' "jellyfin/library: updated library options for '$_rjls_name'"
      else
        printf '%s\n' "jellyfin/library: failed to update library options for '$_rjls_name' (HTTP $_rjls_update_status)" >&2
      fi
    fi
  done
}

run_caddy_local_ca_trust() {
  # Trust Caddy's local CA so certificates from tls internal are recognized by
  # local TLS clients. This applies generally to every local reverse proxy that
  # uses the same Caddy PKI authority, not just Jellyfin.
  #
  # Arguments:
  #   $1 — either "sudo" (run trust with sudo) or "user" (run as current user)
  _rclct_mode="$1"

  if ! command -v caddy >/dev/null 2>&1; then
    printf '%s\n' 'caddy-trust: caddy not found in PATH; skipping local CA trust'
    return
  fi

  _rclct_attempt=0
  while [ "$_rclct_attempt" -lt 20 ]; do
    if [ "$_rclct_mode" = "sudo" ]; then
      if sudo env "PATH=$PATH" caddy trust --address 127.0.0.1:2019; then
        printf '%s\n' 'caddy-trust: local CA trusted successfully'
        return
      fi
    else
      if caddy trust --address 127.0.0.1:2019; then
        printf '%s\n' 'caddy-trust: local CA trusted successfully'
        return
      fi
    fi

    _rclct_attempt=$((_rclct_attempt + 1))
    sleep 1
  done

  printf '%s\n' 'caddy-trust: failed to trust local CA from admin endpoint 127.0.0.1:2019; continuing without failing apply' >&2
}

run_replica_sync() {
  # Call scripts/replica-sync.sh so enabled replicas in users.json are
  # synchronized after a successful apply. This keeps local replica trees
  # (for example iCloudReplica) populated without requiring a separate manual run.
  #
  # Why best-effort: replica convergence is additive and may involve large
  # transfers. A replica error should not retroactively fail a completed
  # system apply.
  if [ "$skip_replica_sync" = true ]; then
    printf '%s\n' "replica-sync: skipping post-apply replica sync (default; pass --replica-sync to run now)"
    return
  fi

  _rrb_script="$REPO_ROOT/scripts/replica-sync.sh"
  if [ ! -f "$_rrb_script" ]; then
    printf '%s\n' "replica-sync: scripts/replica-sync.sh not found at $_rrb_script; skipping replica sync"
    return
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    printf '%s\n' "replica-sync: rclone not found in PATH; skipping post-apply replica sync"
    return
  fi

  printf '%s\n' "replica-sync: running post-apply replica sync..."
  if ! sh "$_rrb_script"; then
    printf '%s\n' "replica-sync: replica-sync.sh exited with an error; replica sync incomplete (system apply succeeded)" >&2
  fi
}

generate_ssh_host_key_if_needed() {
  # Ensure /etc/ssh/ssh_host_ed25519_key exists before
  # register_host_age_key_if_needed tries to derive the machine age public key
  # from it.  On freshly provisioned machines the OS may not have generated host
  # keys yet; ssh-keygen -A creates all standard host key types without
  # overwriting any that already exist, making this call idempotent.
  #
  # Why before register_host_age_key_if_needed:
  #   register_host_age_key_if_needed derives the machine age public key from
  #   /etc/ssh/ssh_host_ed25519_key.pub.  If the key does not exist it skips
  #   registration silently, so the machine can never decrypt its own SOPS
  #   secrets until the operator re-runs apply after the OS has generated the
  #   key.  Generating it here makes first-apply fully self-contained.
  #
  # Requires: sudo session already acquired (start_sudo_keepalive must have
  #   been called before this function).
  # PATH: ssh-keygen is provided by openssh in mkApplyApp runtimeInputs.
  #   The sudo invocation carries PATH explicitly so the Nix-wrapped binary
  #   is found even after sudo resets the environment.
  _gsk_host_key="/etc/ssh/ssh_host_ed25519_key"

  if [ -f "$_gsk_host_key" ]; then
    return
  fi

  printf 'SSH: %s not found; generating SSH host keys...\n' "$_gsk_host_key"
  # Pass PATH explicitly so sudo finds the Nix openssh ssh-keygen rather than
  # any older system ssh-keygen that may be shadowed by runtimeInputs.
  if ! sudo env "PATH=$PATH" ssh-keygen -A; then
    printf 'SSH: ERROR — ssh-keygen -A failed; cannot generate SSH host keys.\n' >&2
    exit 1
  fi

  if [ ! -f "$_gsk_host_key" ]; then
    printf 'SSH: ERROR — ssh-keygen -A completed but %s is still absent.\n' \
      "$_gsk_host_key" >&2
    exit 1
  fi

  printf 'SSH: SSH host keys generated successfully.\n'
}

register_host_age_key_if_needed() {
  # Derive this machine's age public key from its SSH host public key and
  # register it in .sops.yaml as a new recipient, then rewrap every
  # SOPS-encrypted file so the machine can decrypt them on the first apply.
  #
  # Why run before darwin-rebuild / nixos-rebuild:
  #   deriveHostAgeKey (posix-sops.nix) writes /etc/sops/age/machine.txt
  #   only after the system activation completes.  On the first apply the
  #   machine key must already be a .sops.yaml recipient before sops-nix
  #   attempts to decrypt secrets.  The SSH host public key is created by
  #   the OS at install time and is available before any Nix activation.
  #
  # Idempotency: if the derived age public key is already present in
  #   .sops.yaml the function returns immediately (no file is modified).
  #
  # Prerequisites (before calling):
  #   - /etc/ssh/ssh_host_ed25519_key.pub must exist (OS-generated)
  #   - The primary GPG key must be in the keyring so sops updatekeys can
  #     re-encrypt data keys for all recipients including the new machine
  #   - ssh-to-age and sops must be on PATH (provided by mkApplyApp runtimeInputs)
  #   - .sops.yaml must contain the marker comment on its own line:
  #       "    # -- machine keys end; personal SSH backup key below --"
  _rak_host_pub="/etc/ssh/ssh_host_ed25519_key.pub"
  _rak_sops_yaml="$REPO_ROOT/.sops.yaml"

  if [ ! -f "$_rak_host_pub" ]; then
    printf 'sops: %s not found; skipping machine age key auto-registration.\n' \
      "$_rak_host_pub" >&2
    return
  fi

  # Derive the age public key from the SSH host public key (public-key
  # conversion; no passphrase or private key material is accessed).
  _rak_age_pub=""
  if ! _rak_age_pub="$(ssh-to-age -i "$_rak_host_pub")"; then
    printf 'sops: ERROR — ssh-to-age failed to derive age public key from %s.\n' \
      "$_rak_host_pub" >&2
    exit 1
  fi
  if [ -z "$_rak_age_pub" ]; then
    printf 'sops: ERROR — ssh-to-age returned an empty age public key for %s.\n' \
      "$_rak_host_pub" >&2
    exit 1
  fi

  # Idempotency: skip insertion and rewrap when this machine is already registered.
  if grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
    printf 'sops: machine age key already registered in .sops.yaml; skipping auto-registration.\n'
    return
  fi

  printf 'sops: registering machine age key in .sops.yaml and rewrapping SOPS files...\n'

  # Insert the new age key line immediately before the marker comment.
  # The marker delineates machine recipients from the personal SSH backup key
  # so new machines are always inserted above the backup entry.
  # A temp file is used so an interrupted write cannot corrupt .sops.yaml.
  _rak_tmp="$(mktemp)"
  awk -v age_pub="$_rak_age_pub" '
    /    # -- machine keys end; personal SSH backup key below --/ { print "    - " age_pub }
    { print }
  ' "$_rak_sops_yaml" > "$_rak_tmp"
  # mktemp creates files at mode 0600; .sops.yaml is a config file (not a
  # secret) and must be 0644 so other tools can read the recipient list.
  # Set the mode before the atomic rename so the file is never visible at 0600.
  chmod 644 "$_rak_tmp"
  mv "$_rak_tmp" "$_rak_sops_yaml"

  # Verify the insertion succeeded; catches the case where the marker comment
  # was removed or mistyped.
  if ! grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
    printf 'sops: ERROR — failed to insert machine age key into .sops.yaml; is the marker comment present?\n' >&2
    exit 1
  fi

  # Rewrap all SOPS-encrypted files so the new machine recipient can decrypt
  # them.  Requires the primary GPG key in the keyring for re-encryption.
  # The --yes flag skips the interactive "update recipients" confirmation.
  for _rak_secret in \
      "$REPO_ROOT/src/secrets/users-"*.yml \
      "$REPO_ROOT/src/secrets/git-identities.yml" \
      "$REPO_ROOT/src/secrets/gpg-personal.yml" \
      "$REPO_ROOT/src/secrets/ssh-personal.yml"; do
    if [ ! -f "$_rak_secret" ]; then
      continue
    fi
    if ! sops updatekeys --yes "$_rak_secret"; then
      printf 'sops: ERROR — sops updatekeys failed for %s.\n' "$_rak_secret" >&2
      printf 'sops: Ensure the primary GPG key is imported first:\n' >&2
      printf 'sops:   gpg --import <backup-key-file>\n' >&2
      exit 1
    fi
  done

  # Rewrap wallpaper blobs (enumerated at runtime; count is unknown at script
  # parse time).  Read from a temp-file list rather than a pipe so that a
  # `sops updatekeys` failure exits the outer script via set -eu; exit 1
  # inside a pipe subshell would be silently swallowed.
  if [ -d "$REPO_ROOT/src/assets/wallpapers" ]; then
    _rak_wallpaper_list="$(mktemp)"
    find "$REPO_ROOT/src/assets/wallpapers" -name "*.sops" -type f \
      > "$_rak_wallpaper_list"
    while IFS= read -r _rak_wallpaper; do
      if ! sops updatekeys --yes "$_rak_wallpaper"; then
        # Temp file is not explicitly removed here because exit 1 terminates
        # the script immediately; the OS reclaims /tmp files on reboot.
        # Removing it inside the read-loop body would trigger SC2094 (the
        # same variable appears in both `rm` and `done < file`).
        printf 'sops: ERROR — sops updatekeys failed for %s.\n' "$_rak_wallpaper" >&2
        printf 'sops: Ensure the primary GPG key is imported first:\n' >&2
        printf 'sops:   gpg --import <backup-key-file>\n' >&2
        exit 1
      fi
    done < "$_rak_wallpaper_list"
    rm -f "$_rak_wallpaper_list"
  fi

  printf 'sops: machine age key registered and SOPS files rewrapped.\n'
  printf 'sops: Commit the changes before deploying to other machines:\n'
  printf 'sops:   git add .sops.yaml src/secrets src/assets/wallpapers\n'
  printf 'sops:   git commit -m "chore: register <hostname> machine age key"\n'
}

case "$(uname -s)" in
  Darwin)
    # nix-darwin manages both the system layer and the user Home Manager
    # profile.  darwin-rebuild invokes sudo internally for system activation.
    if [ -n "$target_user" ]; then
      printf '%s\n' "apply: --target-user is ignored on Darwin system rebuilds (host-level configuration selects the Home Manager user)."
    fi
    start_sudo_keepalive
    generate_ssh_host_key_if_needed
    register_host_age_key_if_needed
    run_nix run "$REPO_ROOT/src#health-check"
    # `-H` sets HOME to root's home so Nix does not inherit a user-owned HOME
    # while running as root (which otherwise produces ownership warnings).
    run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    ensure_prek_hooks_installed "$REPO_ROOT"
    run_caddy_local_ca_trust sudo
    run_jellyfin_account_sync
    run_jellyfin_library_sync
    run_ai_sync
    run_replica_sync
    run_vm_setup
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      if [ -n "$target_user" ]; then
        printf '%s\n' "apply: --target-user is ignored on NixOS system rebuilds (host-level configuration selects the Home Manager user)."
      fi
      start_sudo_keepalive
      generate_ssh_host_key_if_needed
      register_host_age_key_if_needed
      run_nix run "$REPO_ROOT/src#health-check"
      # Keep root invocations on root-owned HOME for consistent Nix behavior.
      run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      ensure_prek_hooks_installed "$REPO_ROOT"
      run_caddy_local_ca_trust sudo
      run_jellyfin_account_sync
      run_jellyfin_library_sync
      run_ai_sync
      run_replica_sync
      run_vm_setup
      run_gc
      run_gc
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer,
      # no sudo required — keepalive is not started.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${target_user:-${NUCLEUS_USERNAME:-$(id -un)}}"
      run_nix run "$REPO_ROOT/src#health-check"
      run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      ensure_prek_hooks_installed "$REPO_ROOT"
      run_caddy_local_ca_trust user
      run_jellyfin_account_sync
      run_jellyfin_library_sync
      run_ai_sync
      run_replica_sync
      run_vm_setup
      run_gc
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
