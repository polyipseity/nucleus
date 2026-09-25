#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "repo-policy-data" "Repository policy (data-driven)" run_repo_policy_data

# Sub-checks in output order, as "<label>|<function>|<style>".
_POLICY_DATA_CHECKS=(
  "dummy key uniformity|run_dummy_key_uniformity|files"
  "preflight install command policy|run_preflight_install_command_policy|ctx"
  "agents policy|run_agents_policy|files"
  "embedded content enforcement|run_embedded_content_enforcement|files"
  "method-1 symlink resolution|run_method1_symlink_resolution|ctx"
)

run_repo_policy_data() {
  local _ctx_name="$1"
  shift
  run_policy_checks "$_ctx_name" "repository policy (data-driven)" _POLICY_DATA_CHECKS "$@"
}

run_dummy_key_uniformity() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _dummy_registry="src/modules/dummy-keys.json"
  local _dummy_errors=0
  local _dummy_registered _dummy_hits _dummy_files=()
  local _file _rest _line _lit _f

  # Rule: every hardcoded sk- style API key literal (sk-[A-Za-z0-9]{4,}) in tracked files must be a registered dummyKeys value.
  _dummy_registered=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }
  _dummy_hits=$(mktemp) || {
    error "failed to create temp file"
    rm -f "$_dummy_registered"
    return 1
  }
  if [ ! -f "$_dummy_registry" ]; then
    error "dummy-key registry not found at $_dummy_registry"
    rm -f "$_dummy_registered" "$_dummy_hits"
    return 1
  fi
  jq -r '.dummyKeys[].value' "$_dummy_registry" >"$_dummy_registered" 2>/dev/null || {
    error "failed to read dummy-key registry $_dummy_registry"
    rm -f "$_dummy_registered" "$_dummy_hits"
    return 1
  }

  # Exclude this check's own files: their source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _dummy_self_sh
  _dummy_self_sh="$(basename "${BASH_SOURCE[0]}")"
  local _dummy_self_ps1="${_dummy_self_sh%.sh}.ps1"

  if $_has_args; then
    for _f in "${_files[@]}"; do
      # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; secrets/vendor/fixtures are separate concerns and schema prose documents the value format
      case "$_f" in
      src/secrets/* | vendor/* | tests/fixtures/* | *.schema.json) continue ;;
      esac
      case "$(basename "$_f")" in
      "$_dummy_self_sh" | "$_dummy_self_ps1") continue ;;
      esac
      _dummy_files+=("$_f")
    done
  else
    # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; secrets/vendor/fixtures are separate concerns
    mapfile -t _dummy_files < <(
      git ls-files |
        filter_gitignored |
        grep -v -E '^(src/secrets/|vendor/|tests/fixtures/)' |
        grep -v '\.schema\.json$' |
        grep -v -E "(^|/)$_dummy_self_sh$|(^|/)$_dummy_self_ps1$"
    )
  fi

  if [ "${#_dummy_files[@]}" -gt 0 ]; then
    printf '%s\0' "${_dummy_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" grep -HnoE '\bsk-[A-Za-z0-9-]{4,}' 2>/dev/null >"$_dummy_hits" ||
      true # check-suppress:suppression_doc: grep exits 1 when no sk- API key literals are found; zero hits is the expected state

    while IFS= read -r _hit; do
      [ -z "$_hit" ] && continue
      _file="${_hit%%:*}"
      _rest="${_hit#*:}"
      _line="${_rest%%:*}"
      _lit="${_rest#*:}"
      if grep -Fxq "$_lit" "$_dummy_registered"; then
        continue
      fi
      _dummy_errors=$((_dummy_errors + 1))
      error "unregistered dummy API key literal '$_lit' at $_file:$_line (register it in src/modules/dummy-keys.json or use a registered value)"
    done <"$_dummy_hits"
  fi

  rm -f "$_dummy_registered" "$_dummy_hits"

  if [ "$_dummy_errors" -gt 0 ]; then
    error "dummy key uniformity check failed with $_dummy_errors error(s)"
    return 1
  fi
  say "dummy key uniformity policy passed."
  return 0
}

run_preflight_install_command_policy() {
  local -n ctx="$1"
  shift
  local _files=("$@")
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  cd "$_repo_root" || return 1

  local _errors=0
  # Exclude this check's own sibling file: its source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; self-refs are dynamic
  local _self_ps1
  _self_ps1="$(basename "${BASH_SOURCE[0]}" .sh).ps1"

  # Collect PowerShell files
  local -n _ps1_files_ctx="${ctx[PS1_FILES]}"
  local _ps1_files=()
  if $_has_args; then
    if [ ${#_ps1_files_ctx[@]} -gt 0 ]; then
      # Drop this check's own sibling file from the scoped set
      for _f in "${_ps1_files_ctx[@]}"; do
        [ "$(basename "$_f")" = "$_self_ps1" ] || _ps1_files+=("$_f")
      done
    fi
  else
    # Find all .ps1 files outside vendor/ and this check's own sibling
    while IFS= read -r -d '' _f; do
      _ps1_files+=("$_f")
    done < <(find . -name '*.ps1' -not -name "$_self_ps1" -not -path './vendor/*' -not -path './.git/*' -print0)
    # Apply gitignore filter as a second pass (find -print0 uses null separators,
    # which filter_gitignored doesn't support directly)
    mapfile -t _ps1_files < <(printf '%s\n' "${_ps1_files[@]}" | filter_gitignored)
  fi

  if [ "${#_ps1_files[@]}" -gt 0 ]; then
    local _tmpdir
    _tmpdir=$(mktemp -d) || {
      error "failed to create temp dir"
      _errors=$((_errors + 1))
    }

    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_ps1_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _f="$2"
        _out="$1/$(echo "$_f" | tr "/" "_").out"
        grep -Hn "Assert-ToolAvailable.*-InstallCommand" "$_f" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: grep exits 1 when a file has no InstallCommand matches; an empty .out file is the clean state
      ' _ "$_tmpdir"

    local _f _err
    for _f in "$_tmpdir"/*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _errors=$((_errors + 1))
        error "$_err"
      done <"$_f"
    done

    rm -rf -- "$_tmpdir"

    if [ "$_errors" -gt 0 ]; then
      say "  Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
      return 1
    fi
  fi

  say "no preflight InstallCommand violations found."
  return 0
}

run_agents_policy() {
  local _repo_root="$2"
  cd "$_repo_root" || return 1
  local _agents_errors=0

  # Commit-staged body match moved to test suite (14-agents-policy-tests.sh)

  local _instr
  while IFS= read -r -d '' _instr; do
    if ! awk 'NR==1 && $0=="---" {found=1; exit} END{exit !found}' "$_instr"; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing YAML frontmatter opener"
      continue
    fi
    local _desc _name _apply
    _desc=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    _name=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    _apply=$(awk '/^---$/{n++; next} n==1 && /^applyTo:/{sub(/^applyTo: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    if [[ ! "$_desc" =~ ^Use\ when ]]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: description must start with \"Use when\""
    fi
    if [ -z "$_name" ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing name frontmatter field"
    fi
    if [ -z "$_apply" ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing applyTo frontmatter field"
    elif [ "$_apply" = '**' ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: applyTo must not be \"**\" — use scripts/**, src/**, tests/** or narrower"
    fi
  done < <(find .agents/instructions -type f -name '*.instructions.md' -print0)

  local _agents_md="AGENTS.md"
  local _missing_link
  _missing_link=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }
  grep -oE '\.agents/instructions/[a-z0-9-]+\.instructions\.md' "$_agents_md" 2>/dev/null |
    sort -u |
    while IFS= read -r _link; do
      [ -f "$_link" ] || echo "$_link"
    done >"$_missing_link" || true # check-suppress:suppression_doc: grep exits 1 when AGENTS.md has no instruction links; empty missing-link file is valid
  if [ -s "$_missing_link" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "AGENTS.md references missing instruction files:"
    while IFS= read -r _line; do
      error "  $_line"
    done <"$_missing_link"
  else
    say "AGENTS.md instruction links resolve."
  fi
  rm -f "$_missing_link"

  if [ "$_agents_errors" -gt 0 ]; then
    error "agents policy check failed with $_agents_errors error(s)"
    return 1
  fi
  say "agents policy passed."
  return 0
}

run_embedded_content_enforcement() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _errors=0
  # Exclude this check's own file: its source contains the literal heredoc-detection patterns.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _self_sh
  _self_sh="$(basename "${BASH_SOURCE[0]}")"
  # Also exclude the grep-heavy step file which contains a large awk program heredoc
  local _grep_step_sh="11-repo-policy-grep.sh"

  # Embedded-content policy scope for POSIX: src/scripts/** (see .agents/instructions/embedded-content.instructions.md).
  local _sh_files=()
  if $_has_args; then
    filter_scoped_files _sh_files "${_files[@]}" src/scripts '*.sh'
  else
    discover_files _sh_files "$_repo_root" src/scripts '*.sh'
  fi
  # Exclude this check's own file: its source contains the literal heredoc-detection patterns.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _filtered=()
  local _f
  for _f in "${_sh_files[@]}"; do
    [ "$(basename "$_f")" = "$_self_sh" ] || [ "$(basename "$_f")" = "$_grep_step_sh" ] || _filtered+=("$_f")
  done
  _sh_files=("${_filtered[@]}")

  if [ "${#_sh_files[@]}" -gt 0 ]; then
    # Heredoc detector lives in a sibling .awk file (shellcheck policy: extract awk programs >10 lines).
    local _awk_path="$_REPO_POLICY_STEP_DIR/repository-policy.awk"

    local _violation
    while IFS= read -r _violation; do
      _errors=$((_errors + 1))
      error "$_violation"
    done < <(awk -f "$_awk_path" "${_sh_files[@]}")
  fi

  if [ "$_errors" -gt 0 ]; then
    say "  Extract heredocs above 30 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    return 1
  fi

  say "no embedded-content heredoc violations found."
  return 0
}

# run_method1_symlink_resolution — Verify deployed method-1 symlinks point at
# the live repo root, not a read-only /nix/store/*-source snapshot.
# Only runs when the manifest exists (deployed-host requirement).
run_method1_symlink_resolution() {
  local -n ctx="$1"
  local _repo_root="${ctx[REPO_ROOT]}"
  shift
  cd "$_repo_root" || return 1

  local _manifest
  _manifest="$(derive_nucleus_user_root)/method1-symlink-manifest.txt"

  # Skip if manifest doesn't exist (not a deployed host).
  if [ ! -f "$_manifest" ]; then
    say "no method-1 symlink manifest found — skipping."
    return 0
  fi

  local -a _entries=()
  mapfile -t _entries <"$_manifest"

  local _checked=0 _violations=0 _entry _origin _link _target
  local -a _links=()
  for _entry in "${_entries[@]+${_entries[@]}}"; do
    case "$_entry" in
    '' | '#'*) continue ;;
    /*) ;;
    *)
      error "method-1 manifest entry '$_entry' is not an absolute path"
      _violations=$((_violations + 1))
      continue
      ;;
    esac

    _links=()
    if [ -L "$_entry" ]; then
      _links=("$_entry")
      _origin="explicit"
    elif [ -d "$_entry" ]; then
      _origin="walked"
      while IFS= read -r _link; do
        [ "$_link" = "$_entry/extensions" ] && continue
        _links+=("$_link")
      done < <(find "$_entry" -mindepth 1 -maxdepth 1 -type l -print 2>/dev/null)
    else
      continue
    fi

    for _link in "${_links[@]}"; do
      _target="$(readlink "$_link")"
      _checked=$((_checked + 1))
      case "$_target" in
      "$_repo_root"/*)
        ;;
      /nix/store/*-source/*)
        error "method-1 symlink '$_link' resolves to read-only store snapshot: $_target"
        _violations=$((_violations + 1))
        ;;
      /nix/store/*)
        warn "method-1 symlink '$_link' resolves into the Nix store: $_target"
        ;;
      *)
        if [ "$_origin" = "explicit" ]; then
          warn "method-1 symlink '$_link' resolves outside live repo root: $_target"
        fi
        ;;
      esac
    done
  done

  if [ "$_checked" -eq 0 ]; then
    say "0 deployed method-1 symlinks among the manifest entries — nothing to verify."
    return 0
  fi

  if [ "$_violations" -gt 0 ]; then
    error "$_violations method-1 symlink(s) resolve to a read-only store snapshot instead of the live repo root"
    return 1
  fi

  say "verified $_checked method-1 symlink(s) resolve to live repo root ($_repo_root)"
  return 0
}
