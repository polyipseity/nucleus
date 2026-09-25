#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

_REPO_POLICY_STEP_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AWK_PATH="$_REPO_POLICY_STEP_DIR/repository-policy.awk"
# Every repo-policy step file carries the literal pattern text the scans below search
# for, so each scan skips the whole set, itself included.
# ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
_POLICY_STEP_SELF_SH="$(basename "${BASH_SOURCE[0]}")"
_POLICY_STEP_SELF_PS1="${_POLICY_STEP_SELF_SH%.sh}.ps1"

register_step "repo-policy-pattern" "Repository policy (pattern-based)" run_repo_policy_pattern

# Sub-checks in output order, as "<label>|<function>|<style>".
_POLICY_PATTERN_CHECKS=(
  "activation naming policy|run_activation_naming_policy|files"
  "config method compliance|run_config_method_compliance|files"
  "logging format policy|run_logging_format_policy|files"
  "removed skip mechanism|run_removed_skip_mechanism|files"
  "nix file structure|run_nix_file_structure|files"
  "log capture pair policy|run_log_capture_pair_policy|files"
)

run_repo_policy_pattern() {
  local _ctx_name="$1"
  shift
  run_policy_checks "$_ctx_name" "repository policy (pattern-based)" _POLICY_PATTERN_CHECKS "$@"
}

run_config_method_compliance() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _cfg_errors=0
  local _cfg_dir="src/modules/configs"
  local _cfg_par_tmpdir
  _cfg_par_tmpdir=$(mktemp -d) || {
    error "failed to create temp dir"
    _cfg_errors=$((_cfg_errors + 1))
  }

  # Single-pass: collect all config file basenames, run one grep across src/
  local _cfg_patterns
  _cfg_patterns=$(mktemp) || {
    error "failed to create temp file"
    _cfg_errors=$((_cfg_errors + 1))
  }
  find "$_cfg_dir" -type f -exec basename {} \; | sort -u >"$_cfg_patterns"
  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns
  find src/ \( -name '*.nix' -o -name '*.ps1' -o -name '*.sh' \) -not -path '*/vendor/*' -not -path '*/configs/*' -print |
    filter_gitignored |
    xargs grep -n -F -f "$_cfg_patterns" 2>/dev/null ||
    true # check-suppress:suppression_doc: xargs grep exits 1 when no config basename collisions are found; no match is the expected state
  rm -f "$_cfg_patterns"

  # Check for configs. method usage
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  find "$_cfg_dir" -type f -print0 |
    xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _basename=$(basename "$_f")
      # Skip infrastructure files and Nix modules inside configs/  # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
      case "$_basename" in
        .gitkeep|.gitignore|*.schema.json) exit 0 ;;
      esac
      _result_file="$_tmpdir/${_basename}.result"
      _relpath="${_f#*configs/}"
      # Check for disallowed config methods
      if grep -q "^[^#]*configs\." "$_f" 2>/dev/null; then
        echo "ERROR:$_relpath uses configs. method" >> "$_result_file"
      fi
    ' _ "$_cfg_par_tmpdir"

  # Aggregate results
  local _result_file _eline
  for _result_file in "$_cfg_par_tmpdir"/*.result; do
    [ -f "$_result_file" ] || continue
    while IFS= read -r _eline; do
      case "$_eline" in
      ERROR:*)
        _cfg_errors=$((_cfg_errors + 1))
        error "${_eline#ERROR:}"
        ;;
      esac
    done <"$_result_file"
  done
  rm -rf -- "$_cfg_par_tmpdir"

  if [ "$_cfg_errors" -gt 0 ]; then
    error "config method compliance check failed with $_cfg_errors error(s)"
    return 1
  fi
  say "config method compliance passed."
  return 0
}

# Exempt classes: framework-generated and hardcoded names (see
# activation-scripts.instructions.md: Exempt classes).
_activation_name_exempt() {
  case "$1" in
  linkGeneration | writeBoundary | checkLinkTargets | setupLaunchAgents | installPackages | preActivation | extraActivation | postActivation) return 0 ;;
  unprotectSymlink_* | protectSymlink_* | mergeConfig_*) return 0 ;;
  *sops*) return 0 ;;
  esac
  return 1
}

# ref: activation-scripts.instructions.md (Naming conventions) -- policy enforced here
run_activation_naming_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _errors=0
  local _names_file _shared_file _f
  _names_file=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }
  _shared_file=$(mktemp) || {
    error "failed to create temp file"
    rm -f "$_names_file"
    return 1
  }

  # Collect activation entry definitions as "file:line:name" lines across the three
  # namespaces (home.activation, system.activationScripts, nucleus.terminalActivations).
  local _ns_re='(home\.activation|system\.activationScripts|nucleus\.terminalActivations)'
  # Attrset entry lines: name[.sub] = <lib.* value> or name[.sub] = (value on next line).
  # Nested-content lines (config = {, Unit = {, bundle_id = "...") never match.
  # The trailing $ is an EOL anchor inside the pattern value (double-quoted, so no expansion).
  local _entry_re="^[[:space:]]*[a-zA-Z0-9_-]+(\\.[a-zA-Z0-9_-]+)?[[:space:]]*=[[:space:]]*(lib\\.(mkIf|mkAfter|mkBefore|mkForce|mkOverride|mkOrder|hm\\.dag\\.entry(A|Before|Order|After))|[[:space:]]*$)"

  local _nix_files=()
  if $_has_args; then
    filter_scoped_files _nix_files "${_files[@]}" src '*.nix'
  else
    discover_files _nix_files "$_repo_root" src '*.nix'
  fi

  if [ "${#_nix_files[@]}" -gt 0 ]; then
    # Dotted definitions: home.activation.<name> = ...
    printf '%s\0' "${_nix_files[@]}" |
      xargs -0 grep -HnoE "([^a-zA-Z0-9_.]|^)${_ns_re}\\.[a-zA-Z0-9_-]+" 2>/dev/null |
      sed -E 's/^([^:]+:[0-9]+:).*\.([a-zA-Z0-9_-]+)$/\1\2/' >>"$_names_file" ||
      true # check-suppress:suppression_doc: grep exits 1 when no dotted definitions are found; an empty result file is the clean state

    # Attrset definitions: <ns> = { <name> = ...; }; regions (entry-value filter
    # avoids capturing nested-attrset content lines; `=` emits the line number,
    # `paste` pairs it with the extracted name)
    for _f in "${_nix_files[@]}"; do
      sed -nE "/${_ns_re}[[:space:]]*=[^;]*\\{/,/^[[:space:]]*\\};/ {
        /${_entry_re}/ {
          s/^[[:space:]]*([a-zA-Z0-9_-]+).*/\\1/
          =
          p
        }
      }" "$_f" | paste -d: - - | sed "s|^|$_f:|" >>"$_names_file"
    done
  fi

  sort -u -o "$_names_file" "$_names_file"

  # Normalize absolute paths to be relative to the repo root so the
  # regex filters (which expect src/... paths) work correctly.
  if [ -s "$_names_file" ]; then
    local _normalized
    _normalized=$(mktemp)
    sed "s|^${_repo_root}/||" "$_names_file" >"$_normalized"
    mv "$_normalized" "$_names_file"
  fi

  # Names defined outside macOS-scoped paths are cross-platform and need no macos- prefix.
  grep -v -E '^(src/platforms/macOS|src/hosts/MacBook)/' "$_names_file" |
    cut -d: -f3 |
    sort -u >"$_shared_file"
  # Cross-host activation names registered in activation-dag.nix are shared across
  # platforms and need no macos- prefix even when only the macOS file is scanned
  # (scoped mode). Seed the shared set from the canonical registry so the carve-out
  # holds regardless of which files the hook passes.
  if [ -f src/modules/lib/activation-dag.nix ]; then
    grep -oE '"[a-zA-Z0-9_-]+"' src/modules/lib/activation-dag.nix |
      tr -d '"' >>"$_shared_file"
  fi
  sort -u -o "$_shared_file" "$_shared_file"

  local _name _ln
  while IFS=: read -r _f _ln _name; do
    _activation_name_exempt "$_name" && continue
    if [[ ! "$_name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
      _errors=$((_errors + 1))
      error "activation name '$_name' at $_f:$_ln is not kebab-case (see .agents/instructions/activation-scripts.instructions.md)"
    fi
    case "$_name" in
    nucleus-*)
      _errors=$((_errors + 1))
      error "activation name '$_name' at $_f:$_ln uses the forbidden nucleus- prefix (see .agents/instructions/activation-scripts.instructions.md)"
      ;;
    esac
  done <"$_names_file"

  # macOS-scoped entries must carry the macos- prefix unless cross-platform.
  while IFS=: read -r _f _ln _name; do
    _activation_name_exempt "$_name" && continue
    if ! grep -Fxq "$_name" "$_shared_file"; then
      _errors=$((_errors + 1))
      error "macOS-only activation name '$_name' at $_f:$_ln lacks the macos- prefix (see .agents/instructions/activation-scripts.instructions.md)"
    fi
  done < <(grep -E '^(src/platforms/macOS|src/hosts/MacBook)/' "$_names_file" | grep -v ':macos-')

  rm -f "$_names_file" "$_shared_file"

  if [ "$_errors" -gt 0 ]; then
    error "activation naming policy check failed with $_errors error(s)"
    return 1
  fi
  say "activation naming policy passed."
  return 0
}

# True when a pattern scan may read "$1": it matches the caller's extension regex,
# and is neither vendored code, a secret, nor a test fixture (fixtures hold violation
# samples on purpose).
# ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
_policy_scan_target() {
  local _pst_file="$1" _pst_ext_re="$2"
  case "$_pst_file" in
  vendor/* | src/secrets/* | tests/fixtures/*) return 1 ;;
  esac
  case "$(basename "$_pst_file")" in
  "$_POLICY_STEP_SELF_SH" | "$_POLICY_STEP_SELF_PS1" | 11-repo-policy-grep.ps1 | 13-repo-policy-data.ps1) return 1 ;;
  esac
  [[ "$_pst_file" =~ $_pst_ext_re ]]
}

run_logging_format_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _lf_errors=0

  # Logging-format policy scope: tracked script files outside vendored code,
  # secrets, and test fixtures (fixtures deliberately hold violation samples).
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
  local _lf_ext_re='\.(sh|zsh|ps1|psm1)$'
  local _lf_files=()
  local _f
  if $_has_args; then
    for _f in "${_files[@]}"; do
      if _policy_scan_target "$_f" "$_lf_ext_re"; then _lf_files+=("$_f"); fi
    done
  else
    while IFS= read -r _f; do
      if _policy_scan_target "$_f" "$_lf_ext_re"; then _lf_files+=("$_f"); fi
    done < <(git ls-files | filter_gitignored)
  fi

  if [ "${#_lf_files[@]}" -gt 0 ]; then
    # Pattern scan lives in the sibling .awk file (shellcheck policy: extract awk programs >10 lines).
    local _awk_path="$_AWK_PATH"

    local _violation
    while IFS= read -r _violation; do
      _lf_errors=$((_lf_errors + 1))
      error "$_violation"
    done < <(awk -v mode=logging-format -f "$_awk_path" "${_lf_files[@]}")
  fi

  # Self-check: the color spec requires NO_COLOR handling in both shared helpers.
  # Guarded on existence so fixture trees in tests skip this content probe.
  if [ -f src/scripts/lib/lib.sh ] && ! grep -q 'NO_COLOR' src/scripts/lib/lib.sh; then
    _lf_errors=$((_lf_errors + 1))
    error "src/scripts/lib/lib.sh does not reference NO_COLOR (logging-format self-check)"
  fi
  if [ -f src/platforms/Windows/modules/Format-NucleusOutput.psm1 ] && ! grep -q 'NO_COLOR' src/platforms/Windows/modules/Format-NucleusOutput.psm1; then
    _lf_errors=$((_lf_errors + 1))
    error "src/platforms/Windows/modules/Format-NucleusOutput.psm1 does not reference NO_COLOR (logging-format self-check)"
  fi

  if [ "$_lf_errors" -gt 0 ]; then
    error "logging format policy check failed with $_lf_errors error(s)"
    return 1
  fi
  say "logging format policy passed."
  return 0
}

# --- removed skip mechanism --------------------------------------------------------------------
# ref: step-runner.instructions.md -- declared applicability replaces step-level skipping
# Every step declares platform/mode/requires at registration and the runner decides; a step that
# cannot run is reported as not applicable, never as skipped. This scan keeps both halves of that
# contract honest: no step may reintroduce a skip path, and no shared helper may grow one back.
run_removed_skip_mechanism() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _rsk_errors=0
  local _rsk_files=()

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
      src/scripts/* | scripts/* | tests/*) _rsk_files+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r _f; do
      _rsk_files+=("$_f")
    done < <(git ls-files 'src/scripts' 'scripts' 'tests' | filter_gitignored)
  fi

  if [ "${#_rsk_files[@]}" -gt 0 ]; then
    # Pattern scan lives in the sibling .awk file, which excludes the two runners, its own rule
    # list, and both gate steps by filename.
    local _awk_path="$_AWK_PATH"

    local _violation
    while IFS= read -r _violation; do
      _rsk_errors=$((_rsk_errors + 1))
      error "$_violation"
    done < <(awk -v mode=skip-constructs -f "$_awk_path" "${_rsk_files[@]}")
  fi

  if [ "$_rsk_errors" -gt 0 ]; then
    error "skip mechanism removal check failed with $_rsk_errors error(s)"
    return 1
  fi
  say "no removed skip mechanism found."
  return 0
}

# ref: nix-authoring.instructions.md (Nix file structure)
run_nix_file_structure() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _nfs_errors=0
  local _nix_files=()

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
      src/*.nix | tests/*.nix) _nix_files+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _nix_files+=("$_f")
    done < <(find src tests -name '*.nix' -not -path '*/vendor/*' -print0)
    mapfile -t _nix_files < <(printf '%s\n' "${_nix_files[@]}" | filter_gitignored)
  fi

  if [ "${#_nix_files[@]}" -gt 0 ]; then
    local _f _dir _base _dirbase
    for _f in "${_nix_files[@]}"; do
      # Pattern 1: <name>.nix alongside <name>/ directory
      _dir="${_f%.nix}"
      if [ -d "$_dir" ]; then
        _nfs_errors=$((_nfs_errors + 1))
        error "nix file structure: '$_f' exists alongside directory '$_dir/' — move to '$_dir/default.nix' (nix-authoring.instructions.md)"
      fi

      # Pattern 2: <name>/<name>.nix (should be <name>/default.nix)
      _base="$(basename "$_f" .nix)"
      _dirbase="$(basename "$(dirname "$_f")")"
      if [ "$_base" = "$_dirbase" ]; then
        _nfs_errors=$((_nfs_errors + 1))
        error "nix file structure: '$_f' has same name as parent directory — rename to 'default.nix' (nix-authoring.instructions.md)"
      fi
    done
  fi

  if [ "$_nfs_errors" -gt 0 ]; then
    error "nix file structure check failed with $_nfs_errors error(s)"
    return 1
  fi
  say "nix file structure passed."
  return 0
}

# Service log-capture pair policy: a captured service stream always goes to its own
# file, <dir>/stdout.log and <dir>/stderr.log (output-handling.instructions.md).
# Merging the streams, capturing only one, and discarding one to /dev/null are all
# prohibited, on every host.
# WHY the narrow scope: this targets SERVICE capture points only — launchd/systemd
# capture directives and the wrappers that redirect a service's output. Ad-hoc
# `2>/dev/null` on a single command is the suppression-audit concern (step 14).
run_log_capture_pair_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _lcp_errors=0

  # Scope excludes test fixtures, which deliberately hold violation samples.
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
  local _lcp_ext_re='\.(nix|sh|ps1|psm1|yml)$'
  local _lcp_files=()
  local _f
  if $_has_args; then
    for _f in "${_files[@]}"; do
      if _policy_scan_target "$_f" "$_lcp_ext_re"; then _lcp_files+=("$_f"); fi
    done
  else
    while IFS= read -r _f; do
      if _policy_scan_target "$_f" "$_lcp_ext_re"; then _lcp_files+=("$_f"); fi
    done < <(git ls-files | filter_gitignored)
  fi

  local _lcp_discard_re='(StandardOutPath|StandardErrorPath|StandardOutput|StandardError)[[:space:]]*=[[:space:]]*"/dev/null"'
  for _f in "${_lcp_files[@]}"; do
    [ -f "$_f" ] || continue

    # Rule 1: no capture directive may discard a stream.
    if grep -q -E "$_lcp_discard_re" "$_f"; then
      local _lcp_hit
      while IFS= read -r _lcp_hit; do
        _lcp_errors=$((_lcp_errors + 1))
        error "log capture pair: '$_f:$_lcp_hit' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)"
      done < <(grep -n -E "$_lcp_discard_re" "$_f")
    fi

    # Rule 2: no merged-stream redirection.
    if grep -q -F '*>>' "$_f"; then
      local _lcp_merged
      while IFS= read -r _lcp_merged; do
        _lcp_errors=$((_lcp_errors + 1))
        error "log capture pair: '$_f:$_lcp_merged' merges stdout and stderr; use 1>> and 2>> into stdout.log and stderr.log"
      done < <(grep -n -F '*>>' "$_f")
    fi

    # Rule 3: capture is both-or-neither per file, per directive family.
    # WHY boolean presence: a file may own several services, so only the lone-stream
    # case is a violation — with one stream captured and the other discarded, the
    # discarded stream lands in whatever the platform default is.
    local _lcp_launchd_out=false _lcp_launchd_err=false
    if grep -q 'StandardOutPath' "$_f"; then _lcp_launchd_out=true; fi
    if grep -q 'StandardErrorPath' "$_f"; then _lcp_launchd_err=true; fi
    if [ "$_lcp_launchd_out" != "$_lcp_launchd_err" ]; then
      _lcp_errors=$((_lcp_errors + 1))
      error "log capture pair: '$_f' declares only one of StandardOutPath/StandardErrorPath; declare both or neither"
    fi
    local _lcp_systemd_out=false _lcp_systemd_err=false
    if grep -q -E 'StandardOutput[[:space:]]*=' "$_f"; then _lcp_systemd_out=true; fi
    if grep -q -E 'StandardError[[:space:]]*=' "$_f"; then _lcp_systemd_err=true; fi
    if [ "$_lcp_systemd_out" != "$_lcp_systemd_err" ]; then
      _lcp_errors=$((_lcp_errors + 1))
      error "log capture pair: '$_f' declares only one of StandardOutput/StandardError; declare both or neither"
    fi
  done

  if [ "$_lcp_errors" -gt 0 ]; then
    error "log capture pair policy check failed with $_lcp_errors error(s)"
    return 1
  fi
  say "log capture pair policy passed."
  return 0
}
