#!/usr/bin/env bash
# Reads per-user jellyfin declarations from src/modules/users.json, resolves
# credentials from SOPS secrets, and applies them to a running Jellyfin server
# via its HTTP API.

set -euo pipefail

# Variables below are substituted via Nix replaceStrings at build time.
REPO_ROOT='__NUCLEUS_REPO_ROOT__'
_path_prepend='__NUCLEUS_PATH_PREPEND__'

# Fallback when run outside activation context (tokens not substituted).
case "$REPO_ROOT" in __NUCLEUS_*)
  if [ -n "${NUCLEUS_REPO_ROOT:-}" ]; then
    REPO_ROOT="$NUCLEUS_REPO_ROOT"
  else
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/lib.sh"
    REPO_ROOT="$(derive_repo_root)"
  fi
  _path_prepend=''
  ;;
esac

if [ -n "$_path_prepend" ]; then
  export PATH="$_path_prepend:$PATH"
fi

usage() {
  usage_std "$(basename "$0")" "[options]"
  cat <<'EOF'
  --repo-root <path>           Override the detected repository root path.
  --jellyfin-base-url <url>    Jellyfin server base URL (default: read from services.json).
  -h, --help                   Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --jellyfin-base-url)
      JELLYFIN_BASE_URL="$2"
      shift 2
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$(basename "$0")" "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' "jellyfin-sync: curl is not available; skipping sync"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "jellyfin-sync: jq is not available; skipping sync"
  exit 0
fi
if ! command -v sops >/dev/null 2>&1; then
  printf '%s\n' "jellyfin-sync: sops is not available; skipping sync"
  exit 0
fi

_jfs_base_url="${JELLYFIN_BASE_URL:-$(jq -r '.jellyfin.network.http | "http://\(.host):\(.port)"' "$REPO_ROOT/src/modules/services.json" 2>/dev/null || echo "http://127.0.0.1:8096")}"
_jfs_auth_base='MediaBrowser Client="nucleus-apply", DeviceId="posix-apply", Device="POSIX", Version="1.0.0"'

_jfs_api_request() {
  _jfar_method="$1"
  _jfar_path="$2"
  _jfar_token="$3"
  _jfar_body="$4"
  _jfar_url="$_jfs_base_url$_jfar_path"
  _jfar_auth="$_jfs_auth_base"
  if [ -n "$_jfar_token" ]; then
    _jfar_auth="$_jfar_auth, Token=$_jfar_token"
  fi

  if [ -n "$_jfar_body" ]; then
    curl -sS -X "$_jfar_method" "$_jfar_url" \
      -H "Authorization: $_jfar_auth" \
      -H "Content-Type: application/json" \
      --data "$_jfar_body" \
      -w 'HTTPSTATUS:%{http_code}'
  else
    curl -sS -X "$_jfar_method" "$_jfar_url" \
      -H "Authorization: $_jfar_auth" \
      -w 'HTTPSTATUS:%{http_code}'
  fi
}

_jfs_status_from_response() {
  printf '%s' "$1" | sed -n 's/.*HTTPSTATUS:\([0-9][0-9][0-9]\)$/\1/p'
}

_jfs_body_from_response() {
  printf '%s' "$1" | sed 's/HTTPSTATUS:[0-9][0-9][0-9]$//'
}

# Converge Jellyfin user accounts declared in src/modules/users.json.
_jfs_sync_accounts() {
  _jfsa_users_json="$REPO_ROOT/src/modules/users.json"
  if [ ! -f "$_jfsa_users_json" ]; then
    return
  fi

  _jfsa_specs_file="$(mktemp)"
  _jfsa_resolved_file="$(mktemp)"

  jq -cr '
    to_entries[]
    | select(.value | type == "object")
    | . as $u
    | (($u.value.jellyfin.accounts // []) | sort_by(.id)[])
    | {
        owner: $u.key,
        id: .id,
        isAdmin: (.isAdmin // false),
        usernameSecretKey: .usernameSecretKey,
        passwordSecretKey: .passwordSecretKey
      }
  ' "$_jfsa_users_json" > "$_jfsa_specs_file"

  if [ ! -s "$_jfsa_specs_file" ]; then
    rm -f "$_jfsa_specs_file" "$_jfsa_resolved_file"
    return
  fi

  while IFS= read -r _jfsa_spec; do
    _jfsa_owner="$(printf '%s' "$_jfsa_spec" | jq -r '.owner')"
    _jfsa_id="$(printf '%s' "$_jfsa_spec" | jq -r '.id')"
    _jfsa_is_admin_spec="$(printf '%s' "$_jfsa_spec" | jq -r '.isAdmin // false')"
    _jfsa_user_key="$(printf '%s' "$_jfsa_spec" | jq -r '.usernameSecretKey // empty')"
    _jfsa_pass_key="$(printf '%s' "$_jfsa_spec" | jq -r '.passwordSecretKey // empty')"

    if [ -z "$_jfsa_owner" ] || [ -z "$_jfsa_user_key" ] || [ -z "$_jfsa_pass_key" ]; then
      printf '%s\n' "jellyfin: invalid account declaration for id '${_jfsa_id:-<unknown>}'; skipping" >&2
      continue
    fi

    _jfsa_secret_file="$REPO_ROOT/src/secrets/users-${_jfsa_owner}.yml"
    if [ ! -f "$_jfsa_secret_file" ]; then
      printf '%s\n' "jellyfin: missing users-${_jfsa_owner}.yml; skipping account declaration '${_jfsa_id}'" >&2
      continue
    fi

    if ! _jfsa_secret_json="$(sops --decrypt --output-type json "$_jfsa_secret_file")"; then
      printf '%s\n' "jellyfin: failed to decrypt $_jfsa_secret_file; skipping account declaration '${_jfsa_id}'" >&2
      continue
    fi

    _jfsa_username="$(printf '%s' "$_jfsa_secret_json" | jq -r --arg key "$_jfsa_user_key" '.[$key] // empty')"
    _jfsa_password="$(printf '%s' "$_jfsa_secret_json" | jq -r --arg key "$_jfsa_pass_key" '.[$key] // empty')"
    if [ -z "$_jfsa_username" ] || [ -z "$_jfsa_password" ]; then
      printf '%s\n' "jellyfin: missing secret values for account declaration '${_jfsa_id}' in users-${_jfsa_owner}.yml" >&2
      continue
    fi

    jq -cn \
      --arg owner "$_jfsa_owner" \
      --arg id "$_jfsa_id" \
      --arg username "$_jfsa_username" \
      --arg password "$_jfsa_password" \
      --argjson isAdmin "$_jfsa_is_admin_spec" \
      '{owner:$owner,id:$id,username:$username,password:$password,isAdmin:$isAdmin}' >> "$_jfsa_resolved_file"
  done < "$_jfsa_specs_file"

  rm -f "$_jfsa_specs_file"
  if [ ! -s "$_jfsa_resolved_file" ]; then
    rm -f "$_jfsa_resolved_file"
    return
  fi

  # Probe readiness; startup can lag behind service registration after apply.
  _jfsa_waited=0
  while [ "$_jfsa_waited" -lt 60 ]; do
    if curl -fsS --max-time 5 "$_jfs_base_url/System/Info/Public" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    _jfsa_waited=$((_jfsa_waited + 1))
  done

  if [ "$_jfsa_waited" -ge 60 ]; then
    printf '%s\n' "jellyfin: API at $_jfs_base_url is not reachable; skipping account sync"
    rm -f "$_jfsa_resolved_file"
    return
  fi

  _jfsa_admin_token=""
  while IFS= read -r _jfsa_account; do
    _jfsa_username="$(printf '%s' "$_jfsa_account" | jq -r '.username')"
    _jfsa_password="$(printf '%s' "$_jfsa_account" | jq -r '.password')"
    _jfsa_desired_admin="$(printf '%s' "$_jfsa_account" | jq -r '.isAdmin // false')"

    _jfsa_auth_payload="$(jq -cn --arg username "$_jfsa_username" --arg password "$_jfsa_password" '{Username:$username,Pw:$password}')"
    _jfsa_auth_response="$(_jfs_api_request POST '/Users/AuthenticateByName' '' "$_jfsa_auth_payload")"
    _jfsa_auth_status="$(_jfs_status_from_response "$_jfsa_auth_response")"
    if [ "$_jfsa_auth_status" != "200" ]; then
      continue
    fi

    _jfsa_token="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_auth_response")" | jq -r '.AccessToken // empty')"
    if [ -z "$_jfsa_token" ]; then
      continue
    fi

    _jfsa_me_response="$(_jfs_api_request GET '/Users/Me' "$_jfsa_token" '')"
    _jfsa_me_status="$(_jfs_status_from_response "$_jfsa_me_response")"
    if [ "$_jfsa_me_status" != "200" ]; then
      continue
    fi

    _jfsa_is_admin="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_me_response")" | jq -r '.Policy.IsAdministrator // false')"
    if [ "$_jfsa_is_admin" = "true" ]; then
      _jfsa_admin_token="$_jfsa_token"
      break
    fi
  done < "$_jfsa_resolved_file"

  if [ -z "$_jfsa_admin_token" ]; then
    _jfsa_bootstrap_account="$(head -n 1 "$_jfsa_resolved_file")"
    _jfsa_bootstrap_username="$(printf '%s' "$_jfsa_bootstrap_account" | jq -r '.username')"
    _jfsa_bootstrap_password="$(printf '%s' "$_jfsa_bootstrap_account" | jq -r '.password')"
    _jfsa_startup_payload="$(jq -cn --arg name "$_jfsa_bootstrap_username" --arg password "$_jfsa_bootstrap_password" '{Name:$name,Password:$password}')"

    _jfsa_startup_response="$(_jfs_api_request POST '/Startup/User' '' "$_jfsa_startup_payload")"
    _jfsa_startup_status="$(_jfs_status_from_response "$_jfsa_startup_response")"
    if [ "$_jfsa_startup_status" = "204" ]; then
      _jfsa_complete_response="$(_jfs_api_request POST '/Startup/Complete' '' '')"
      _jfsa_complete_status="$(_jfs_status_from_response "$_jfsa_complete_response")"
      if [ "$_jfsa_complete_status" != "204" ]; then
        printf '%s\n' "jellyfin: startup completion returned HTTP $_jfsa_complete_status" >&2
      fi
    fi

    _jfsa_bootstrap_auth_payload="$(jq -cn --arg username "$_jfsa_bootstrap_username" --arg password "$_jfsa_bootstrap_password" '{Username:$username,Pw:$password}')"
    _jfsa_bootstrap_attempt=0
    while [ "$_jfsa_bootstrap_attempt" -lt 15 ] && [ -z "$_jfsa_admin_token" ]; do
      _jfsa_bootstrap_auth_response="$(_jfs_api_request POST '/Users/AuthenticateByName' '' "$_jfsa_bootstrap_auth_payload")"
      _jfsa_bootstrap_auth_status="$(_jfs_status_from_response "$_jfsa_bootstrap_auth_response")"
      if [ "$_jfsa_bootstrap_auth_status" = "200" ]; then
        _jfsa_bootstrap_token="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_bootstrap_auth_response")" | jq -r '.AccessToken // empty')"
        if [ -n "$_jfsa_bootstrap_token" ]; then
          _jfsa_bootstrap_me_response="$(_jfs_api_request GET '/Users/Me' "$_jfsa_bootstrap_token" '')"
          _jfsa_bootstrap_me_status="$(_jfs_status_from_response "$_jfsa_bootstrap_me_response")"
          if [ "$_jfsa_bootstrap_me_status" = "200" ]; then
            _jfsa_bootstrap_is_admin="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_bootstrap_me_response")" | jq -r '.Policy.IsAdministrator // false')"
            if [ "$_jfsa_bootstrap_is_admin" = "true" ]; then
              _jfsa_admin_token="$_jfsa_bootstrap_token"
              break
            fi
          fi
        fi
      fi
      sleep 1
      _jfsa_bootstrap_attempt=$((_jfsa_bootstrap_attempt + 1))
    done
  fi

  if [ -z "$_jfsa_admin_token" ]; then
    printf '%s\n' "jellyfin: no elevated account credentials available; skipping account sync"
    rm -f "$_jfsa_resolved_file"
    return
  fi

  while IFS= read -r _jfsa_account; do
    _jfsa_username="$(printf '%s' "$_jfsa_account" | jq -r '.username')"
    _jfsa_password="$(printf '%s' "$_jfsa_account" | jq -r '.password')"

    _jfsa_users_response="$(_jfs_api_request GET '/Users' "$_jfsa_admin_token" '')"
    _jfsa_users_status="$(_jfs_status_from_response "$_jfsa_users_response")"
    if [ "$_jfsa_users_status" != "200" ]; then
      printf '%s\n' "jellyfin: failed to list users (HTTP $_jfsa_users_status); stopping account sync" >&2
      break
    fi
    _jfsa_users_body="$(_jfs_body_from_response "$_jfsa_users_response")"

    _jfsa_user_id="$(printf '%s' "$_jfsa_users_body" | jq -r --arg username "$_jfsa_username" 'map(select(.Name == $username)) | .[0].Id // empty')"

    if [ -z "$_jfsa_user_id" ]; then
      _jfsa_create_payload="$(jq -cn --arg name "$_jfsa_username" --arg password "$_jfsa_password" '{Name:$name,Password:$password}')"
      _jfsa_create_response="$(_jfs_api_request POST '/Users/New' "$_jfsa_admin_token" "$_jfsa_create_payload")"
      _jfsa_create_status="$(_jfs_status_from_response "$_jfsa_create_response")"
      if [ "$_jfsa_create_status" = "200" ]; then
        printf '%s\n' "jellyfin: created account '$_jfsa_username'"
        _jfsa_user_id="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_create_response")" | jq -r '.Id // empty')"
        if [ -z "$_jfsa_user_id" ]; then
          printf '%s\n' "jellyfin: created account '$_jfsa_username' but could not resolve user id for policy sync" >&2
          continue
        fi
      else
        printf '%s\n' "jellyfin: failed to create account '$_jfsa_username' (HTTP $_jfsa_create_status)" >&2
        continue
      fi
    fi

    _jfsa_user_detail_response="$(_jfs_api_request GET "/Users/${_jfsa_user_id}" "$_jfsa_admin_token" '')"
    _jfsa_user_detail_status="$(_jfs_status_from_response "$_jfsa_user_detail_response")"
    if [ "$_jfsa_user_detail_status" != "200" ]; then
      printf '%s\n' "jellyfin: failed to query account details for '$_jfsa_username' (HTTP $_jfsa_user_detail_status)" >&2
      continue
    fi

    _jfsa_user_policy_json="$(printf '%s' "$(_jfs_body_from_response "$_jfsa_user_detail_response")" | jq -c '.Policy // empty')"
    if [ -z "$_jfsa_user_policy_json" ]; then
      printf '%s\n' "jellyfin: missing policy payload for account '$_jfsa_username'; skipping admin policy sync" >&2
      continue
    fi

    _jfsa_current_admin="$(printf '%s' "$_jfsa_user_policy_json" | jq -r '.IsAdministrator // false')"
    if [ "$_jfsa_current_admin" != "$_jfsa_desired_admin" ]; then
      _jfsa_updated_policy="$(printf '%s' "$_jfsa_user_policy_json" | jq -c --argjson isAdmin "$_jfsa_desired_admin" '.IsAdministrator = $isAdmin')"
      _jfsa_policy_update_response="$(_jfs_api_request POST "/Users/${_jfsa_user_id}/Policy" "$_jfsa_admin_token" "$_jfsa_updated_policy")"
      _jfsa_policy_update_status="$(_jfs_status_from_response "$_jfsa_policy_update_response")"
      if [ "$_jfsa_policy_update_status" = "204" ]; then
        printf '%s\n' "jellyfin: updated admin policy for account '$_jfsa_username' to $_jfsa_desired_admin"
      else
        printf '%s\n' "jellyfin: failed to update admin policy for account '$_jfsa_username' (HTTP $_jfsa_policy_update_status)" >&2
      fi
    fi

    _jfsa_check_payload="$(jq -cn --arg username "$_jfsa_username" --arg password "$_jfsa_password" '{Username:$username,Pw:$password}')"
    _jfsa_check_response="$(_jfs_api_request POST '/Users/AuthenticateByName' '' "$_jfsa_check_payload")"
    _jfsa_check_status="$(_jfs_status_from_response "$_jfsa_check_response")"
    if [ "$_jfsa_check_status" = "200" ]; then
      continue
    fi

    _jfsa_password_payload="$(jq -cn --arg password "$_jfsa_password" '{ResetPassword:false,NewPw:$password}')"
    _jfsa_password_response="$(_jfs_api_request POST "/Users/Password?userId=${_jfsa_user_id}" "$_jfsa_admin_token" "$_jfsa_password_payload")"
    _jfsa_password_status="$(_jfs_status_from_response "$_jfsa_password_response")"
    if [ "$_jfsa_password_status" = "204" ]; then
      printf '%s\n' "jellyfin: updated password for account '$_jfsa_username'"
    else
      printf '%s\n' "jellyfin: failed to update password for account '$_jfsa_username' (HTTP $_jfsa_password_status)" >&2
    fi
  done < "$_jfsa_resolved_file"

  rm -f "$_jfsa_resolved_file"
}

# Converge Jellyfin library folders declared in src/modules/users.json.
_jfs_sync_libraries() {
  _jfsl_users_json="$REPO_ROOT/src/modules/users.json"
  if [ ! -f "$_jfsl_users_json" ]; then
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

  _jfsl_specs_file="$(mktemp)"
  _jfsl_creds_file="$(mktemp)"

  jq -cr '
    to_entries[]
    | select(.value | type == "object")
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
  ' "$_jfsl_users_json" > "$_jfsl_specs_file"

  while IFS= read -r _jfsl_spec; do
    _jfsl_owner="$(printf '%s' "$_jfsl_spec" | jq -r '.owner')"
    _jfsl_secret_file="$REPO_ROOT/src/secrets/users-${_jfsl_owner}.yml"
    if [ ! -f "$_jfsl_secret_file" ]; then
      continue
    fi

    if ! _jfsl_secret_json="$(sops --decrypt --output-type json "$_jfsl_secret_file")"; then
      continue
    fi

    jq -cr --arg owner "$_jfsl_owner" '
      .[$owner].jellyfin.accounts // [] | .[]
      | {owner: $owner} + .
    ' "$_jfsl_users_json" 2>/dev/null | while IFS= read -r _jfsl_account; do
      _jfsl_user_key="$(printf '%s' "$_jfsl_account" | jq -r '.usernameSecretKey // empty')"
      _jfsl_pass_key="$(printf '%s' "$_jfsl_account" | jq -r '.passwordSecretKey // empty')"
      if [ -z "$_jfsl_user_key" ] || [ -z "$_jfsl_pass_key" ]; then
        continue
      fi
      _jfsl_username="$(printf '%s' "$_jfsl_secret_json" | jq -r --arg key "$_jfsl_user_key" '.[$key] // empty')"
      _jfsl_password="$(printf '%s' "$_jfsl_secret_json" | jq -r --arg key "$_jfsl_pass_key" '.[$key] // empty')"
      if [ -z "$_jfsl_username" ] || [ -z "$_jfsl_password" ]; then
        continue
      fi
      printf '%s\n' "$(jq -cn --arg owner "$_jfsl_owner" --arg username "$_jfsl_username" --arg password "$_jfsl_password" '{owner:$owner,username:$username,password:$password}')"
    done
  done < "$_jfsl_specs_file" > "$_jfsl_creds_file"

  if [ ! -s "$_jfsl_specs_file" ]; then
    rm -f "$_jfsl_specs_file" "$_jfsl_creds_file"
    return
  fi

  _jfsl_resolved_file="$(mktemp)"
  while IFS= read -r _jfsl_spec; do
    _jfsl_owner="$(printf '%s' "$_jfsl_spec" | jq -r '.owner')"
    _jfsl_home="$(printf '%s' "$_jfsl_spec" | jq -r '.home')"
    _jfsl_name="$(printf '%s' "$_jfsl_spec" | jq -r '.name')"
    _jfsl_collection_type="$(printf '%s' "$_jfsl_spec" | jq -r '.collectionType')"
    _jfsl_options="$(printf '%s' "$_jfsl_spec" | jq -c '.options')"

    _jfsl_paths_json="$(printf '%s' "$_jfsl_spec" | jq -c '.paths')"
    _jfsl_resolved_paths_json="$(printf '%s' "$_jfsl_paths_json" | jq -c --arg home "$_jfsl_home" '
      map(if startswith("~/") then ($home + .[1:]) else . end)
    ')"

    jq -cn \
      --arg owner "$_jfsl_owner" \
      --arg name "$_jfsl_name" \
      --arg collectionType "$_jfsl_collection_type" \
      --argjson paths "$_jfsl_resolved_paths_json" \
      --argjson options "$_jfsl_options" \
      '{owner:$owner,name:$name,collectionType:$collectionType,paths:$paths,options:$options}' >> "$_jfsl_resolved_file"
  done < "$_jfsl_specs_file"

  rm -f "$_jfsl_specs_file"

  if [ ! -s "$_jfsl_resolved_file" ]; then
    rm -f "$_jfsl_resolved_file" "$_jfsl_creds_file"
    return
  fi

  _jfsl_merged_file="$(mktemp)"
  _jfsl_merge_input="$(mktemp)"
  while IFS= read -r _jfsl_line; do printf '%s\n' "$_jfsl_line"; done < "$_jfsl_resolved_file" > "$_jfsl_merge_input"
  jq -s '
    group_by(.name | ascii_downcase)
    | map(.[0])
    | to_entries
    | map(.value)
  ' "$_jfsl_merge_input" > "$_jfsl_merged_file" 2>/dev/null || cat "$_jfsl_resolved_file" > "$_jfsl_merged_file"
  rm -f "$_jfsl_merge_input"

  rm -f "$_jfsl_resolved_file"

  _jfsl_waited=0
  while [ "$_jfsl_waited" -lt 60 ]; do
    if curl -fsS --max-time 5 "$_jfs_base_url/System/Info/Public" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    _jfsl_waited=$((_jfsl_waited + 1))
  done

  if [ "$_jfsl_waited" -ge 60 ]; then
    printf '%s\n' "jellyfin/library: API at $_jfs_base_url is not reachable; skipping library sync"
    rm -f "$_jfsl_merged_file" "$_jfsl_creds_file"
    return
  fi

  _jfsl_admin_token=""
  while IFS= read -r _jfsl_cred; do
    _jfsl_username="$(printf '%s' "$_jfsl_cred" | jq -r '.username')"
    _jfsl_password="$(printf '%s' "$_jfsl_cred" | jq -r '.password')"

    _jfsl_auth_payload="$(jq -cn --arg username "$_jfsl_username" --arg password "$_jfsl_password" '{Username:$username,Pw:$password}')"
    _jfsl_auth_response="$(_jfs_api_request POST '/Users/AuthenticateByName' '' "$_jfsl_auth_payload")"
    _jfsl_auth_status="$(_jfs_status_from_response "$_jfsl_auth_response")"
    if [ "$_jfsl_auth_status" != "200" ]; then
      continue
    fi

    _jfsl_token="$(printf '%s' "$(_jfs_body_from_response "$_jfsl_auth_response")" | jq -r '.AccessToken // empty')"
    if [ -z "$_jfsl_token" ]; then
      continue
    fi

    _jfsl_me_response="$(_jfs_api_request GET '/Users/Me' "$_jfsl_token" '')"
    _jfsl_me_status="$(_jfs_status_from_response "$_jfsl_me_response")"
    if [ "$_jfsl_me_status" != "200" ]; then
      continue
    fi

    _jfsl_is_admin="$(printf '%s' "$(_jfs_body_from_response "$_jfsl_me_response")" | jq -r '.Policy.IsAdministrator // false')"
    if [ "$_jfsl_is_admin" = "true" ]; then
      _jfsl_admin_token="$_jfsl_token"
      break
    fi
  done < "$_jfsl_creds_file"

  if [ -z "$_jfsl_admin_token" ]; then
    _jfsl_bootstrap_cred="$(head -n 1 "$_jfsl_creds_file")"
    if [ -n "$_jfsl_bootstrap_cred" ]; then
      _jfsl_bootstrap_username="$(printf '%s' "$_jfsl_bootstrap_cred" | jq -r '.username')"
      _jfsl_bootstrap_password="$(printf '%s' "$_jfsl_bootstrap_cred" | jq -r '.password')"
      _jfsl_startup_payload="$(jq -cn --arg name "$_jfsl_bootstrap_username" --arg password "$_jfsl_bootstrap_password" '{Name:$name,Password:$password}')"
      _jfsl_startup_response="$(_jfs_api_request POST '/Startup/User' '' "$_jfsl_startup_payload")"
      _jfsl_startup_status="$(_jfs_status_from_response "$_jfsl_startup_response")"
      if [ "$_jfsl_startup_status" = "204" ]; then
        _jfs_complete_response="$(_jfs_api_request POST '/Startup/Complete' '' '')"
      fi

      _jfsl_bootstrap_attempt=0
      while [ "$_jfsl_bootstrap_attempt" -lt 15 ] && [ -z "$_jfsl_admin_token" ]; do
        _jfsl_bootstrap_auth_response="$(_jfs_api_request POST '/Users/AuthenticateByName' '' "$_jfsl_startup_payload")"
        _jfsl_bootstrap_auth_status="$(_jfs_status_from_response "$_jfsl_bootstrap_auth_response")"
        if [ "$_jfsl_bootstrap_auth_status" = "200" ]; then
          _jfsl_bootstrap_token="$(printf '%s' "$(_jfs_body_from_response "$_jfsl_bootstrap_auth_response")" | jq -r '.AccessToken // empty')"
          if [ -n "$_jfsl_bootstrap_token" ]; then
            _jfsl_bootstrap_me_response="$(_jfs_api_request GET '/Users/Me' "$_jfsl_bootstrap_token" '')"
            _jfsl_bootstrap_is_admin="$(printf '%s' "$(_jfs_body_from_response "$_jfsl_bootstrap_me_response")" | jq -r '.Policy.IsAdministrator // false')"
            if [ "$_jfsl_bootstrap_is_admin" = "true" ]; then
              _jfsl_admin_token="$_jfsl_bootstrap_token"
              break
            fi
          fi
        fi
        sleep 1
        _jfsl_bootstrap_attempt=$((_jfsl_bootstrap_attempt + 1))
      done
    fi
  fi

  if [ -z "$_jfsl_admin_token" ]; then
    printf '%s\n' "jellyfin/library: no elevated account credentials available; skipping library sync"
    rm -f "$_jfsl_merged_file" "$_jfsl_creds_file"
    return
  fi

  rm -f "$_jfsl_creds_file"

  _jfsl_folders_response="$(_jfs_api_request GET '/Library/VirtualFolders' "$_jfsl_admin_token" '')"
  _jfsl_folders_status="$(_jfs_status_from_response "$_jfsl_folders_response")"
  if [ "$_jfsl_folders_status" != "200" ]; then
    printf '%s\n' "jellyfin/library: failed to list virtual folders (HTTP $_jfsl_folders_status); skipping"
    rm -f "$_jfsl_merged_file"
    return
  fi
  _jfsl_folders_body="$(_jfs_body_from_response "$_jfsl_folders_response")"

  _jfsl_libs="$(cat "$_jfsl_merged_file")"
  rm -f "$_jfsl_merged_file"

  printf '%s' "$_jfsl_libs" | jq -c '.[]' | while IFS= read -r _jfsl_lib; do
    _jfsl_name="$(printf '%s' "$_jfsl_lib" | jq -r '.name')"
    _jfsl_collection_type="$(printf '%s' "$_jfsl_lib" | jq -r '.collectionType')"
    _jfsl_paths="$(printf '%s' "$_jfsl_lib" | jq -c '.paths')"
    _jfsl_options="$(printf '%s' "$_jfsl_lib" | jq -c '.options')"

    _jfsl_backdrop_limit="$(printf '%s' "$_jfsl_options" | jq -r '.imageOptions.Backdrop.limit // 1')"
    _jfsl_backdrop_minwidth="$(printf '%s' "$_jfsl_options" | jq -r '.imageOptions.Backdrop.minWidth // 1280')"
    _jfsl_logo_limit="$(printf '%s' "$_jfsl_options" | jq -r '.imageOptions.Logo.limit // 1')"
    _jfsl_primary_limit="$(printf '%s' "$_jfsl_options" | jq -r '.imageOptions.Primary.limit // 1')"
    _jfsl_image_fetchers="$(printf '%s' "$_jfsl_options" | jq -c '.imageFetchers // ["Embedded Image Extractor","Screen Grabber"]')"

    _jfsl_library_options="$(jq -cn \
      --argjson enabled "$(printf '%s' "$_jfsl_options" | jq '.enabled // true')" \
      --argjson enableRealtimeMonitor "$(printf '%s' "$_jfsl_options" | jq '.enableRealtimeMonitor // true')" \
      --argjson enableEmbeddedTitles "$(printf '%s' "$_jfsl_options" | jq '.enableEmbeddedTitles // true')" \
      --argjson enableEmbeddedExtrasTitles "$(printf '%s' "$_jfsl_options" | jq '.enableEmbeddedExtrasTitles // false')" \
      --arg allowEmbeddedSubtitles "$(printf '%s' "$_jfsl_options" | jq -r '.allowEmbeddedSubtitles // "AllowAll"')" \
      --argjson saveLocalMetadata "$(printf '%s' "$_jfsl_options" | jq '.saveLocalMetadata // false')" \
      --argjson enableChapterImageExtraction "$(printf '%s' "$_jfsl_options" | jq '.enableChapterImageExtraction // true')" \
      --argjson extractChapterImagesDuringLibraryScan "$(printf '%s' "$_jfsl_options" | jq '.extractChapterImagesDuringLibraryScan // false')" \
      --argjson enableTrickplayImageExtraction "$(printf '%s' "$_jfsl_options" | jq '.enableTrickplayImageExtraction // true')" \
      --argjson extractTrickplayImagesDuringLibraryScan "$(printf '%s' "$_jfsl_options" | jq '.extractTrickplayImagesDuringLibraryScan // false')" \
      --argjson saveTrickplayWithMedia "$(printf '%s' "$_jfsl_options" | jq '.saveTrickplayWithMedia // false')" \
      --argjson imageFetchers "$_jfsl_image_fetchers" \
      --argjson backdropLimit "$_jfsl_backdrop_limit" \
      --argjson backdropMinWidth "$_jfsl_backdrop_minwidth" \
      --argjson logoLimit "$_jfsl_logo_limit" \
      --argjson primaryLimit "$_jfsl_primary_limit" \
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

    _jfsl_existing_item_id="$(printf '%s' "$_jfsl_folders_body" | jq -r --arg name "$_jfsl_name" '
      map(select(.Name == $name))
      | .[0]
      | (.ItemId // .Id // empty)
    ')"

    if [ -z "$_jfsl_existing_item_id" ]; then
      _jfsl_query_params="name=$(printf '%s' "$_jfsl_name" | jq -sRr @uri)&collectionType=$(printf '%s' "$_jfsl_collection_type" | jq -sRr @uri)"
      _jfsl_paths_file="$(mktemp)"
      printf '%s' "$_jfsl_paths" | jq -r '.[]' > "$_jfsl_paths_file"
      while IFS= read -r _jfsl_path; do
        _jfsl_query_params="$_jfsl_query_params&paths=$(printf '%s' "$_jfsl_path" | jq -sRr @uri)"
      done < "$_jfsl_paths_file"
      rm -f "$_jfsl_paths_file"
      _jfsl_create_payload="$(jq -cn --argjson options "$_jfsl_library_options" --argjson paths "$_jfsl_paths" '{LibraryOptions:$options,Paths:$paths,RefreshLibrary:true}')"
      _jfsl_create_response="$(_jfs_api_request POST "/Library/VirtualFolders?${_jfsl_query_params}" "$_jfsl_admin_token" "$_jfsl_create_payload")"
      _jfsl_create_status="$(_jfs_status_from_response "$_jfsl_create_response")"
      if [ "$_jfsl_create_status" = "204" ]; then
        printf '%s\n' "jellyfin/library: created library '$_jfsl_name' ($_jfsl_collection_type)"
        _jfs_api_request POST '/Library/Refresh' "$_jfsl_admin_token" '' >/dev/null
      else
        printf '%s\n' "jellyfin/library: failed to create library '$_jfsl_name' (HTTP $_jfsl_create_status)" >&2
      fi
    else
      _jfsl_update_payload="$(jq -cn --arg id "$_jfsl_existing_item_id" --argjson options "$_jfsl_library_options" '{Id:$id,LibraryOptions:$options}')"
      _jfsl_update_response="$(_jfs_api_request POST '/Library/VirtualFolders/LibraryOptions' "$_jfsl_admin_token" "$_jfsl_update_payload")"
      _jfsl_update_status="$(_jfs_status_from_response "$_jfsl_update_response")"
      if [ "$_jfsl_update_status" = "204" ]; then
        printf '%s\n' "jellyfin/library: updated library options for '$_jfsl_name'"
        _jfs_api_request POST '/Library/Refresh' "$_jfsl_admin_token" '' >/dev/null
      else
        printf '%s\n' "jellyfin/library: failed to update library options for '$_jfsl_name' (HTTP $_jfsl_update_status)" >&2
      fi
    fi
  done
}

_jfs_sync_accounts
_jfs_sync_libraries
