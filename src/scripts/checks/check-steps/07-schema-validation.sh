# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "schema-validation" 7 "Schema validation (JSON/YAML)" run_07_schema_validation

run_07_schema_validation() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _jsonschema_errors=0
  local _js_tmpdir
  _js_tmpdir=$(mktemp -d) || {
    error "failed to create temp directory"
    return 1
  }

  # Collect file -- schema pairs into a temp manifest.
  local _js_manifest="$_js_tmpdir/manifest"
  local _js_schema_files=()

  if $_has_args; then
    for _sf in "${_files[@]}"; do
      case "$_sf" in *.json | *.yml | *.yaml) _js_schema_files+=("$_sf") ;; esac
    done
  else
    _js_schema_files=("${CACHED_JSON_FILES[@]}")
    for _yf in "${CACHED_YAML_FILES[@]}"; do
      _js_schema_files+=("$_yf")
    done
  fi

  # $schema presence and format check (Spec G)
  local _missing_schema=0
  for _f in "${_js_schema_files[@]}"; do
    # Exception list (Spec G): *.schema.json, vendor/**, secrets/**,
    # */.github/workflows/*.yml, */.github/dependabot.yml, package.json, opencode.jsonc
    # + app-owned formats with no published JSON schema (vscode:// URIs are not
    # fetchable by check-jsonschema; other formats have no published schema).
    case "$_f" in
    *.schema.json | */vendor/* | */secrets/* | .github/workflows/* | */.github/workflows/* | */.github/dependabot.yml | .github/dependabot.yml)
      continue
      ;;
    */users/*/vscode/*.json | */users/*/iterm2/DynamicProfiles/*.json | */users/*/obsidian/*.json | */users/*/qtpass/*.json | */configs/camilladsp/* | */configs/camillagui-backend/* | */users/*/discord-music-rpc/* | */users/*/agents/hooks/*.json | */users/*/agents/skills/*/_meta.json | */ai/litellm-config.yml | */.sops.yaml)
      continue
      ;;
    esac
    local _sf_nobase="${_f##*/}"
    case "$_sf_nobase" in
    package.json | opencode.jsonc) continue ;;
    esac

    case "$_f" in
    *.json)
      _has_schema=$(jq -r 'if type == "object" then (has("$schema") | tostring) else "false" end' "$_f" 2>/dev/null)
      if [ "$_has_schema" = "true" ]; then
        _schema_val=$(jq -r 'if type == "object" then (."$schema" // "") else "" end' "$_f" 2>/dev/null)
        if [ -z "$_schema_val" ]; then
          error "Invalid \$schema in $_f: must be a non-empty string"
          _missing_schema=$((_missing_schema + 1))
        fi
      else
        error "Missing \$schema in $_f"
        _missing_schema=$((_missing_schema + 1))
      fi
      ;;
    *.yml | *.yaml)
      # shellcheck disable=SC2016 # reason: literal $schema in yq eval expression
      _has_schema=$(yq eval 'has("$schema")' "$_f" 2>/dev/null)
      if [ "$_has_schema" = "true" ]; then
        # shellcheck disable=SC2016 # reason: literal $schema in yq eval expression
        _schema_val=$(yq eval '."$schema" // ""' "$_f" 2>/dev/null)
        if [ -z "$_schema_val" ]; then
          error "Invalid \$schema in $_f: must be a non-empty string"
          _missing_schema=$((_missing_schema + 1))
        fi
      else
        error "Missing \$schema in $_f"
        _missing_schema=$((_missing_schema + 1))
      fi
      ;;
    esac
  done
  _jsonschema_errors=$((_jsonschema_errors + _missing_schema))

  if [ "${#_js_schema_files[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_js_schema_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _tmpdir="$1"
        _f="$2"
        _safe="$(echo "$_f" | tr "/" "_")"
        case "$_f" in
          *.json)
            _schema=$(jq -r "if type == \"object\" then .[\"\$schema\"] // \"\" else \"\" end" "$_f" 2>/dev/null)
            ;;
          *.yml|*.yaml)
            _schema=$(yq eval ".\$schema // \"\"" "$_f" 2>/dev/null)
            ;;
        esac
        if [ -n "$_schema" ]; then
          case "$_schema" in
            http://*|https://*) ;;
            ./*|../*)
              _schemafile="$(cd "$(dirname "$_f")" && echo "$(pwd)/${_schema#./}")"
              printf "%s\t%s\n" "$_schemafile" "$_f" > "$_tmpdir/${_safe}.schema"
              ;;
            *)
              printf "%s\t%s\n" "$_schema" "$_f" > "$_tmpdir/${_safe}.schema"
              ;;
          esac
        fi
      ' _ "$_js_tmpdir"

    true >"$_js_manifest"
    for _sf in "$_js_tmpdir"/*.schema; do
      [ -f "$_sf" ] && cat "$_sf" >>"$_js_manifest"
    done
  fi

  # Group by schema and dispatch via xargs -P
  if [ -s "$_js_manifest" ]; then
    sort -k1 "$_js_manifest" | awk -F'\t' '
      BEGIN { gid = 0; cur = "" }
      {
        if ($1 != cur) {
          if (cur != "") close(f)
          gid++; cur = $1
          f = "'"$_js_tmpdir"'/g-" gid ".sch"
          print $1 > f
        }
        print $2 >> f
      }
      END { if (cur != "") close(f) }
    '
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    if [ -n "$(find "$_js_tmpdir" -maxdepth 1 -name 'g-*.sch' -print 2>/dev/null | head -1)" ]; then
      printf '%s\0' "$_js_tmpdir"/g-*.sch |
        xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
          _tmpdir="$1"
          _batch="$2"
          _schemafile=""
          _files=()
          while IFS= read -r _line; do
            if [ -z "$_schemafile" ]; then
              _schemafile="$_line"
            else
              _files+=("$_line")
            fi
          done < "$_batch"
          _safe="$(echo "$_schemafile" | tr "/" "_")"
          if check-jsonschema --schemafile "$_schemafile" "${_files[@]}" 2>> "$_tmpdir/${_safe}.err"; then
            echo "PASS" > "$_tmpdir/${_safe}.st"
          else
            echo "FAIL" > "$_tmpdir/${_safe}.st"
          fi
        ' _ "$_js_tmpdir"

      for _st_file in "$_js_tmpdir"/*.st; do
        [ -f "$_st_file" ] || continue
        read -r _status <"$_st_file"
        [ "$_status" = "FAIL" ] && _jsonschema_errors=$((_jsonschema_errors + 1))
      done
      for _err_file in "$_js_tmpdir"/*.err; do
        [ -s "$_err_file" ] || continue
        while IFS= read -r _line; do
          error "$_line"
        done <"$_err_file"
      done
    fi
  fi

  # GitHub schema validation -- always-run
  check-jsonschema --builtin-schema vendor.github-workflows .github/workflows/*.yml || _jsonschema_errors=$((_jsonschema_errors + 1))
  check-jsonschema --builtin-schema vendor.dependabot .github/dependabot.yml || _jsonschema_errors=$((_jsonschema_errors + 1))

  [ -n "${_js_tmpdir:-}" ] && rm -rf -- "$_js_tmpdir"

  if [ "$_jsonschema_errors" -gt 0 ]; then
    error "schema validation failed with $_jsonschema_errors error(s)"
    return 1
  fi
  say "schema validation passed."
  return 0
}
