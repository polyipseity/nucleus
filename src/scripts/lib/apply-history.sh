# shellcheck shell=sh
# Apply history (append-only JSONL) writer/reader helpers.
[ -n "${_NUCLEUS_APPLY_HISTORY_SOURCED-}" ] && return
_NUCLEUS_APPLY_HISTORY_SOURCED=1

apply_history_path() {
  if [ -n "${NUCLEUS_USER_ROOT-}" ]; then
    printf '%s/state/apply/history.jsonl\n' "$NUCLEUS_USER_ROOT"
    return 0
  fi
  if command -v derive_nucleus_user_root >/dev/null 2>&1; then
    printf '%s/state/apply/history.jsonl\n' "$(derive_nucleus_user_root)"
    return 0
  fi
  case "$(uname -s)" in
  Darwin) printf '%s\n' "$HOME/Library/Application Support/nucleus/state/apply/history.jsonl" ;;
  *) printf '%s\n' "$HOME/.local/share/nucleus/state/apply/history.jsonl" ;;
  esac
}

_apply_history_config_file() {
  printf '%s\n' "$HOME/.local/state/nucleus/config.json"
}

apply_history_get_limit() {
  # Default 256 per plan; 0 disables writes, negative unlimited.
  _ahl_config="$(_apply_history_config_file)"
  if [ ! -f "$_ahl_config" ]; then
    printf '256\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '256\n'
    return 0
  fi
  # check-suppress:suppression_doc: invalid/missing config falls back to default limit
  _ahl_val="$(jq -r 'if has("applyHistoryLimit") and (.applyHistoryLimit != null) then (.applyHistoryLimit | tostring) else empty end' "$_ahl_config" 2>/dev/null || true)"
  case "$_ahl_val" in
  '') printf '256\n' ;;
  *[!0-9-]*) printf '256\n' ;;
  *) printf '%s\n' "$_ahl_val" ;;
  esac
}

_apply_history_now_rfc3339_utc() {
  # RFC3339 UTC with finest precision available; milliseconds floor when %N is
  # unavailable (macOS BSD date may not provide nanoseconds).
  # check-suppress:suppression_doc: %N unsupported on some date implementations
  _ahn_ns="$(date -u +%N 2>/dev/null || true)"
  case "$_ahn_ns" in
  *[!0-9]* | '')
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
    ;;
  *)
    # Take first 3 digits for milliseconds
    _ahn_ms="$(printf '%s' "$_ahn_ns" | cut -c1-3)"
    printf '%s.%sZ\n' "$(date -u +"%Y-%m-%dT%H:%M:%S")" "$_ahn_ms"
    ;;
  esac
}

_apply_history_git_fields() {
  # Sets global-ish vars: _ahg_commitHash _ahg_branch _ahg_detachedHead _ahg_appliedCommitTag _ahg_lastTagOnBranch
  # _ahg_hasUnstaged _ahg_hasStaged _ahg_hasUntracked _ahg_isDirty
  _ahg_repoRoot="$1"
  _ahg_commitHash="null"
  _ahg_branch="null"
  _ahg_detachedHead="null"
  _ahg_appliedCommitTag="null"
  _ahg_lastTagOnBranch="null"
  _ahg_hasUnstaged="null"
  _ahg_hasStaged="null"
  _ahg_hasUntracked="null"
  _ahg_isDirty="null"

  if [ -z "$_ahg_repoRoot" ] || [ ! -d "$_ahg_repoRoot" ]; then
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$_ahg_repoRoot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  # commitHash (short)
  # check-suppress:suppression_doc: best-effort git field derivation
  _ahg_commitHash="$(git -C "$_ahg_repoRoot" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "$_ahg_commitHash" ]; then _ahg_commitHash="null"; fi

  # branch
  # check-suppress:suppression_doc: best-effort git field derivation
  _ahg_branch="$(git -C "$_ahg_repoRoot" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$_ahg_branch" ]; then _ahg_branch="null"; fi

  # detachedHead
  if git -C "$_ahg_repoRoot" symbolic-ref -q HEAD >/dev/null 2>&1; then
    _ahg_detachedHead="false"
  else
    _ahg_detachedHead="true"
  fi

  # appliedCommitTag: newest tag at HEAD
  # check-suppress:suppression_doc: no tag at HEAD is not an error
  _ahg_tag="$(git -C "$_ahg_repoRoot" tag --points-at HEAD --sort=-creatordate 2>/dev/null | head -1 || true)"
  if [ -n "$_ahg_tag" ]; then
    _ahg_appliedCommitTag="$_ahg_tag"
  else
    _ahg_appliedCommitTag="null"
  fi

  # lastTagOnBranch: nearest reachable tag
  # check-suppress:suppression_doc: no reachable tag is not an error
  _ahg_lasttag="$(git -C "$_ahg_repoRoot" describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -n "$_ahg_lasttag" ]; then
    _ahg_lastTagOnBranch="$_ahg_lasttag"
  else
    _ahg_lastTagOnBranch="null"
  fi

  # porcelain parsing
  # check-suppress:suppression_doc: best-effort working tree status parsing
  _ahg_porcelain="$(git -C "$_ahg_repoRoot" status --porcelain 2>/dev/null || true)"
  _ahg_hasUnstaged="false"
  _ahg_hasStaged="false"
  _ahg_hasUntracked="false"
  if [ -n "$_ahg_porcelain" ]; then
    _ahg_oldIFS="$IFS"
    IFS='
'
    for _ahg_line in $_ahg_porcelain; do
      IFS="$_ahg_oldIFS"
      # Skip empty
      [ -z "$_ahg_line" ] && continue
      case "$_ahg_line" in
      '??'*) _ahg_hasUntracked="true" ;;
      *)
        # XY format: char1 = index, char2 = worktree
        _ahg_x="${_ahg_line%"${_ahg_line#?}"}" # first char
        _ahg_rest="${_ahg_line#?}"
        _ahg_y="${_ahg_rest%"${_ahg_rest#?}"}" # second char
        if [ "$_ahg_x" != ' ' ] && [ "$_ahg_x" != '?' ]; then
          _ahg_hasStaged="true"
        fi
        if [ "$_ahg_y" != ' ' ]; then
          _ahg_hasUnstaged="true"
        fi
        ;;
      esac
    done
    IFS="$_ahg_oldIFS"
  fi
  if [ "$_ahg_hasUnstaged" = "true" ] || [ "$_ahg_hasStaged" = "true" ] || [ "$_ahg_hasUntracked" = "true" ]; then
    _ahg_isDirty="true"
  else
    _ahg_isDirty="false"
  fi
}

apply_history_record() {
  # result phase repoRoot host user
  _ahr_result="$1"
  _ahr_phase="$2"
  _ahr_repoRoot="$3"
  _ahr_host="$4"
  _ahr_user="$5"

  _ahr_limit="$(apply_history_get_limit)"
  case "$_ahr_limit" in
  0) return 0 ;;
  esac

  require_command jq

  _ahr_path="$(apply_history_path)"
  _ahr_dir="$(dirname "$_ahr_path")"
  mkdir -p "$_ahr_dir"

  _ahr_appliedAt="$(_apply_history_now_rfc3339_utc)"

  # Git fields
  _apply_history_git_fields "$_ahr_repoRoot"

  # Build JSON record
  _ahr_phase_json="null"
  if [ -n "$_ahr_phase" ] && [ "$_ahr_phase" != "null" ]; then
    _ahr_phase_json="$(printf '%s' "$_ahr_phase" | jq -Rs .)"
  fi

  # For git fields that are "null" strings (meaning JSON null), convert; others that are actual values need to be JSON-quoted strings except booleans
  _ahr_commitHash_json="null"
  if [ "$_ahg_commitHash" != "null" ]; then
    _ahr_commitHash_json="$(printf '%s' "$_ahg_commitHash" | jq -Rs .)"
  fi
  _ahr_branch_json="null"
  if [ "$_ahg_branch" != "null" ]; then
    _ahr_branch_json="$(printf '%s' "$_ahg_branch" | jq -Rs .)"
  fi
  _ahr_detachedHead_json="null"
  if [ "$_ahg_detachedHead" != "null" ]; then
    _ahr_detachedHead_json="$([ "$_ahg_detachedHead" = "true" ] && printf 'true' || printf 'false')"
  fi
  _ahr_appliedCommitTag_json="null"
  if [ "$_ahg_appliedCommitTag" != "null" ]; then
    _ahr_appliedCommitTag_json="$(printf '%s' "$_ahg_appliedCommitTag" | jq -Rs .)"
  fi
  _ahr_lastTagOnBranch_json="null"
  if [ "$_ahg_lastTagOnBranch" != "null" ]; then
    _ahr_lastTagOnBranch_json="$(printf '%s' "$_ahg_lastTagOnBranch" | jq -Rs .)"
  fi
  _ahr_hasUnstaged_json="null"
  if [ "$_ahg_hasUnstaged" != "null" ]; then
    _ahr_hasUnstaged_json="$([ "$_ahg_hasUnstaged" = "true" ] && printf 'true' || printf 'false')"
  fi
  _ahr_hasStaged_json="null"
  if [ "$_ahg_hasStaged" != "null" ]; then
    _ahr_hasStaged_json="$([ "$_ahg_hasStaged" = "true" ] && printf 'true' || printf 'false')"
  fi
  _ahr_hasUntracked_json="null"
  if [ "$_ahg_hasUntracked" != "null" ]; then
    _ahr_hasUntracked_json="$([ "$_ahg_hasUntracked" = "true" ] && printf 'true' || printf 'false')"
  fi
  _ahr_isDirty_json="null"
  if [ "$_ahg_isDirty" != "null" ]; then
    _ahr_isDirty_json="$([ "$_ahg_isDirty" = "true" ] && printf 'true' || printf 'false')"
  fi

  _ahr_repoRoot_json="$(printf '%s' "$_ahr_repoRoot" | jq -Rs .)"
  _ahr_host_json="$(printf '%s' "$_ahr_host" | jq -Rs .)"
  _ahr_user_json="$(printf '%s' "$_ahr_user" | jq -Rs .)"
  _ahr_result_json="$(printf '%s' "$_ahr_result" | jq -Rs .)"

  _ahr_line="$(
    jq -nc \
      --argjson version 1 \
      --arg appliedAt "$_ahr_appliedAt" \
      --argjson result "$_ahr_result_json" \
      --argjson phase "$_ahr_phase_json" \
      --argjson host "$_ahr_host_json" \
      --argjson user "$_ahr_user_json" \
      --argjson repoRoot "$_ahr_repoRoot_json" \
      --argjson commitHash "$_ahr_commitHash_json" \
      --argjson branch "$_ahr_branch_json" \
      --argjson detachedHead "$_ahr_detachedHead_json" \
      --argjson appliedCommitTag "$_ahr_appliedCommitTag_json" \
      --argjson lastTagOnBranch "$_ahr_lastTagOnBranch_json" \
      --argjson hasUnstaged "$_ahr_hasUnstaged_json" \
      --argjson hasStaged "$_ahr_hasStaged_json" \
      --argjson hasUntracked "$_ahr_hasUntracked_json" \
      --argjson isDirty "$_ahr_isDirty_json" \
      '{version:$version,appliedAt:$appliedAt,result:$result,phase:$phase,host:$host,user:$user,repoRoot:$repoRoot,commitHash:$commitHash,branch:$branch,detachedHead:$detachedHead,appliedCommitTag:$appliedCommitTag,lastTagOnBranch:$lastTagOnBranch,hasUnstaged:$hasUnstaged,hasStaged:$hasStaged,hasUntracked:$hasUntracked,isDirty:$isDirty}'
  )"

  # Append, then trim if needed
  if [ -f "$_ahr_path" ]; then
    # Preserve mode
    _ahr_mode="$(stat -f '%Lp' "$_ahr_path" 2>/dev/null || stat -c '%a' "$_ahr_path" 2>/dev/null || printf '644')"
  else
    _ahr_mode="644"
  fi

  # Read existing lines and append/trim in a temp file in the same directory
  # (same-filesystem rename for atomic replace).
  _ahr_tmp="$(mktemp "${_ahr_dir}/.history.XXXXXX")"
  if [ -f "$_ahr_path" ]; then
    # check-suppress:suppression_doc: unreadable history treated as empty before append
    cat "$_ahr_path" >"$_ahr_tmp" 2>/dev/null || true
  fi
  printf '%s\n' "$_ahr_line" >>"$_ahr_tmp"

  # Trim if limit >= 0
  if [ "$_ahr_limit" -ge 0 ] 2>/dev/null; then
    _ahr_total="$(wc -l <"$_ahr_tmp" | tr -d ' ')"
    if [ "$_ahr_total" -gt "$_ahr_limit" ] 2>/dev/null; then
      # Keep newest _ahr_limit lines
      tail -n "$_ahr_limit" "$_ahr_tmp" >"${_ahr_tmp}.trim" && mv "${_ahr_tmp}.trim" "$_ahr_tmp"
    fi
  fi

  # Atomic replace
  mv "$_ahr_tmp" "$_ahr_path"
  # check-suppress:suppression_doc: best-effort mode restoration after rename
  chmod "$_ahr_mode" "$_ahr_path" 2>/dev/null || true
}

# Reads all entries from history file. Outputs one JSON object per line (oldest first).
# Returns 1 and prints to stderr if any line is corrupt (naming the line number, 1-based).
apply_history_read_all_entries() {
  _ahra_path="$(apply_history_path)"
  if [ ! -f "$_ahra_path" ]; then
    return 0
  fi
  if [ ! -s "$_ahra_path" ]; then
    return 0
  fi
  require_command jq
  _ahra_line_no=0
  while IFS= read -r _ahra_line || [ -n "$_ahra_line" ]; do
    _ahra_line_no=$((_ahra_line_no + 1))
    # Skip completely empty lines? Probably not expected, but be lenient? No, say corrupt? Or skip. But better to be strict: empty line is corrupt.
    if [ -z "$(printf '%s' "$_ahra_line" | tr -d '[:space:]')" ]; then
      printf 'apply-history: corrupt line %s: empty line\n' "$_ahra_line_no" >&2
      return 1
    fi
    if ! printf '%s' "$_ahra_line" | jq -e . >/dev/null 2>&1; then
      printf 'apply-history: corrupt line %s: invalid JSON\n' "$_ahra_line_no" >&2
      return 1
    fi
    printf '%s\n' "$_ahra_line"
  done <"$_ahra_path"
}

# Outputs JSON {"version":1,"entries":[...]} with newest first.
# If n is given, returns at most n entries. If missing/empty file, entries is [].
apply_history_read_entries_json() {
  _ahre_n="${1:-}"
  _ahre_path="$(apply_history_path)"
  if [ ! -f "$_ahre_path" ] || [ ! -s "$_ahre_path" ]; then
    printf '{"version":1,"entries":[]}\n'
    return 0
  fi
  _ahre_all="$(apply_history_read_all_entries)" || return 1
  if [ -z "$_ahre_all" ]; then
    printf '{"version":1,"entries":[]}\n'
    return 0
  fi
  # Reverse and take n
  if [ -n "$_ahre_n" ]; then
    printf '%s\n' "$_ahre_all" | jq -s --argjson n "$_ahre_n" 'reverse | .[0:$n]' | jq -c '{version:1,entries:.}'
  else
    printf '%s\n' "$_ahre_all" | jq -s 'reverse' | jq -c '{version:1,entries:.}'
  fi
}

# Human-readable newest entry (for status). Returns 1 if corrupt.
apply_history_read_latest_human() {
  _ahrl_json="$(apply_history_read_entries_json 1)" || return 1
  _ahrl_count="$(printf '%s' "$_ahrl_json" | jq '.entries | length')"
  if [ "$_ahrl_count" -eq 0 ]; then
    printf 'No apply history yet.\n'
    return 0
  fi
  printf '%s' "$_ahrl_json" | jq -r '.entries[0] | "result: \(.result)\nphase: \(.phase)\nappliedAt: \(.appliedAt)\nhost: \(.host)\nuser: \(.user)\nrepoRoot: \(.repoRoot)\ncommitHash: \(.commitHash)\nbranch: \(.branch)\ndetachedHead: \(.detachedHead)\nappliedCommitTag: \(.appliedCommitTag)\nlastTagOnBranch: \(.lastTagOnBranch)\nhasUnstaged: \(.hasUnstaged)\nhasStaged: \(.hasStaged)\nhasUntracked: \(.hasUntracked)\nisDirty: \(.isDirty)"'
}
