#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

_REPO_POLICY_STEP_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AWK_PATH="$_REPO_POLICY_STEP_DIR/repository-policy.awk"
# Every repo-policy step file carries the literal pattern text the scans search
# for, so each scan skips the whole set, itself included.
# ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
_POLICY_STEP_SELF_SH="$(basename "${BASH_SOURCE[0]}")"
_POLICY_STEP_SELF_PS1="${_POLICY_STEP_SELF_SH%.sh}.ps1"

register_step "repo-policy-pattern" "Repository policy (pattern-based)" run_repo_policy_pattern posix any none

_POLICY_PATTERN_CHECKS=(
  "activation naming policy|run_activation_naming_policy|files"
  "config method compliance|run_config_method_compliance|files"
  "logging format policy|run_logging_format_policy|files"
  "removed skip mechanism|run_removed_skip_mechanism|files"
  "nix file structure|run_nix_file_structure|files"
  "log capture pair policy|run_log_capture_pair_policy|files"
  "envrc ban policy|run_envrc_ban_policy|files"
  "prompt template contract|run_prompt_template_contract|files"
)

run_repo_policy_pattern() {
  local _ctx_name="$1"
  shift
  run_policy_checks "$_ctx_name" "repository policy (pattern-based)" _POLICY_PATTERN_CHECKS "$@"
}

# A config referenced from outside the configs tree must carry the registered
# config-method annotation on the reference line or within the 10 lines above
# it. This mirrors 12-repo-policy-pattern.ps1: the two scans it replaces printed
# matches that never failed a run and flagged text no instruction defines, so
# neither could enforce anything.
# WHY whole-repo in both modes: a reference can live in any src/ file, so a
#   scoped subset cannot prove the annotation is absent; the .ps1 twin scans
#   the same way.
run_config_method_compliance() {
  local _repo_root="$2"
  shift 2
  cd "$_repo_root" || return 1
  local _cfg_errors=0
  local _cfg_dir="src/modules/configs"

  if [ ! -d "$_cfg_dir" ]; then
    say "config method compliance passed."
    return 0
  fi

  # Reference files: every Nix, PowerShell, and shell source outside vendored
  # code and the configs tree itself, so a config never counts as its own ref.
  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns
  local _src_files=()
  if [ -d src/ ]; then
    mapfile -t _src_files < <(
      find src/ \( -name '*.nix' -o -name '*.ps1' -o -name '*.sh' \) -not -path '*/vendor/*' -not -path '*/configs/*' -print |
        filter_gitignored
    )
  fi

  # Checkable configs in find order, with the patterns each one is looked up
  # by: its relative path, its basename, and, when the basename has an
  # extension, the ${hostName} template form.
  local _cfgs=() _bases=() _tmpls=()
  local _cfg _rel _base
  while IFS= read -r -d '' _cfg; do
    _base="${_cfg##*/}"
    # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
    case "$_base" in
    .gitkeep | .gitignore | *.schema.json | *.nix) continue ;;
    esac
    _rel="${_cfg#"$_cfg_dir"/}"
    case "$_rel" in
    agents/* | hermes-agent/SOUL.md | ollama/models.json) continue ;;
    esac
    _cfgs+=("$_rel")
    _bases+=("$_base")
    # A templated form needs a dot past the first character, matching the twin's
    # $dotIndex -gt 0: a dot-prefixed basename has an empty stem and none.
    if [ -z "${_base%%.*}" ] || [ "$_base" = "${_base%%.*}" ]; then
      _tmpls+=("")
    else
      _tmpls+=("\${hostName}.${_base#*.}")
    fi
  done < <(find "$_cfg_dir" -type f -print0)

  if [ "${#_cfgs[@]}" -eq 0 ]; then
    say "config method compliance passed."
    return 0
  fi

  # Reference index: one grep for every config basename, which also serves the
  # relative-path tier because a relative path contains its basename, and one
  # grep for the template forms. The tiers below read this index, so the tree is
  # never scanned again per config.
  local _ref_index="" _tmpl_index=""
  local _pat_args=() _tmpl_args=() _pat
  for _pat in "${_bases[@]}"; do
    _pat_args+=(-e "$_pat")
  done
  for _pat in "${_tmpls[@]}"; do
    [ -n "$_pat" ] && _tmpl_args+=(-e "$_pat")
  done
  if [ "${#_src_files[@]}" -gt 0 ]; then
    _ref_index=$(grep -HnF "${_pat_args[@]}" "${_src_files[@]}" || true) # check-suppress:suppression_doc: grep exits 1 when no source file references a config; every config then reports no references
    if [ "${#_tmpl_args[@]}" -gt 0 ]; then
      _tmpl_index=$(grep -HnF "${_tmpl_args[@]}" "${_src_files[@]}" || true) # check-suppress:suppression_doc: grep exits 1 when no template line references a config; the template tier then stays empty
    fi
  fi

  # Annotation index as "file:line" keys, so the 10-line window below is a
  # lookup and needs no subprocess.
  local -A _annot=()
  local _key
  if [ "${#_src_files[@]}" -gt 0 ]; then
    while IFS= read -r _key; do
      [ -n "$_key" ] && _annot["$_key"]=1
    done < <(grep -HnF '# check-suppress:config-method' "${_src_files[@]}" | cut -d: -f1,2)
  fi

  local _i _line _refs _ref _ref_file _ref_line _annotated _tmpl _pn _lo
  for ((_i = 0; _i < ${#_cfgs[@]}; _i++)); do
    _rel="${_cfgs[_i]}"
    _base="${_bases[_i]}"
    _tmpl="${_tmpls[_i]}"

    # Reference tiers in the .ps1 twin's order: relative path, then basename,
    # then the ${hostName} template suffix. A tier that matches replaces the
    # refs from the tiers above it, so the annotation applies to one tier.
    _refs=""
    if [ -n "$_ref_index" ]; then
      while IFS= read -r _line; do
        [[ $_line == *"$_rel"* ]] && _refs+="$_line"$'\n'
      done <<<"$_ref_index"
      if [ -z "$_refs" ]; then
        while IFS= read -r _line; do
          [[ $_line == *"$_base"* ]] && _refs+="$_line"$'\n'
        done <<<"$_ref_index"
      fi
    fi
    if [ -z "$_refs" ] && [ -n "$_tmpl" ] && [ -n "$_tmpl_index" ]; then
      while IFS= read -r _line; do
        [[ $_line == *"$_tmpl"* ]] && _refs+="$_line"$'\n'
      done <<<"$_tmpl_index"
    fi

    # Annotation-only rule: a config with no reference outside configs/ has
    # nothing to annotate.
    [ -n "$_refs" ] || continue

    _annotated=false
    while IFS= read -r _ref; do
      [ -n "$_ref" ] || continue
      _ref_file="${_ref%%:*}"
      _ref_line="${_ref#*:}"
      _ref_line="${_ref_line%%:*}"
      if [ -n "${_annot["$_ref_file:$_ref_line"]-}" ]; then
        _annotated=true
        break
      fi
      _lo=$((_ref_line - 10))
      for ((_pn = _ref_line - 1; _pn >= _lo && _pn >= 1; _pn--)); do
        if [ -n "${_annot["$_ref_file:$_pn"]-}" ]; then
          _annotated=true
          break
        fi
      done
      if $_annotated; then
        break
      fi
    done <<<"$_refs"

    if ! $_annotated; then
      error "$_rel : referenced but no '# check-suppress:config-method' comment found on or before reference lines"
      _cfg_errors=$((_cfg_errors + 1))
    fi
  done

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

  # Dotted definitions as "file:line:name", anywhere in a file: the three
  # namespaces written out as `home.activation.<name>`.
  local _ns_re='(home\.activation|system\.activationScripts|nucleus\.terminalActivations)'

  local _nix_files=()
  if $_has_args; then
    filter_scoped_files _nix_files "${_files[@]}" src '*.nix'
  else
    discover_files _nix_files "$_repo_root" src '*.nix'
  fi

  if [ "${#_nix_files[@]}" -gt 0 ]; then
    printf '%s\0' "${_nix_files[@]}" |
      xargs -0 grep -HnoE "([^a-zA-Z0-9_.]|^)${_ns_re}\\.[a-zA-Z0-9_-]+" 2>/dev/null |
      sed -E 's/^([^:]+:[0-9]+:).*\.([a-zA-Z0-9_-]+)$/\1\2/' >>"$_names_file" ||
      true # check-suppress:suppression_doc: grep exits 1 when no dotted definitions are found; an empty result file is the clean state

    # Attrset definitions: `<ns> = { <name> = ...; }` regions, in one pass for
    # the whole list. The sed|paste|sed loop this replaces forked three children
    # per file and took 0.30 s of this rule's 0.45 s here; the region and entry
    # rules now live in the shared program.
    local _awk_path="$_AWK_PATH"
    # Nothing in this call chain enables errexit, so an unguarded failure would
    # fall through to the pass message.
    awk -v mode=activation-naming -f "$_awk_path" "${_nix_files[@]}" >>"$_names_file" || return 1
  fi

  sort -u -o "$_names_file" "$_names_file"

  # The filters expect src/... paths, so strip the absolute repo root.
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
  # Cross-host names registered in activation-dag.nix are shared even when only a
  # macOS file is scanned, so seed the shared set from that canonical registry.
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

# A pattern scan may read "$1" when it matches the caller's extension regex and is
# not vendored code, a secret, or a test fixture (fixtures hold violation samples).
# ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
_policy_scan_target() {
  local _pst_file="$1" _pst_ext_re="$2"
  case "$_pst_file" in
  vendor/* | src/secrets/* | tests/fixtures/*) return 1 ;;
  esac
  # ${x##*/} rather than basename: this runs once per tracked file, where the
  # forks cost more than the scan itself.
  case "${_pst_file##*/}" in
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

  # The color spec requires NO_COLOR in both shared helpers; the existence guard
  # lets a fixture tree skip the probe.
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

# ref: step-runner.instructions.md -- declared applicability replaces step-level skipping
# Every step declares platform/mode/requires at registration and the runner
# decides, so a step that cannot run is never skipped. No step may reintroduce a
# skip path, and no shared helper may grow one back.
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
    # The .awk file excludes the two runners, its own rule list, and both gate steps.
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
      _dir="${_f%.nix}"
      if [ -d "$_dir" ]; then
        _nfs_errors=$((_nfs_errors + 1))
        error "nix file structure: '$_f' exists alongside directory '$_dir/' — move to '$_dir/default.nix' (nix-authoring.instructions.md)"
      fi

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

# A captured service stream always goes to its own file, <dir>/stdout.log and
# <dir>/stderr.log (output-handling.instructions.md). Merging the streams,
# capturing one, and discarding one to /dev/null are prohibited on every host.
# WHY the narrow scope: this targets SERVICE capture points (launchd/systemd
# directives and the wrappers that redirect a service's output). An ad-hoc
# `2>/dev/null` on one command belongs to the suppression audit (step 11).
run_log_capture_pair_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _lcp_errors=0

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

  local _lcp_scan=()
  for _f in "${_lcp_files[@]}"; do
    if [ -f "$_f" ]; then _lcp_scan+=("$_f"); fi
  done

  # One pass for the whole list. The grep version spawned up to nine children
  # per file, which was 9.1 s of the 12.6 s step here; the mode carries both the
  # messages and their per-file report order, so the output is unchanged.
  if [ "${#_lcp_scan[@]}" -gt 0 ]; then
    local _awk_path="$_AWK_PATH"
    local _violation
    while IFS= read -r _violation; do
      _lcp_errors=$((_lcp_errors + 1))
      error "$_violation"
    done < <(awk -v mode=log-capture -f "$_awk_path" "${_lcp_scan[@]}")
  fi

  if [ "$_lcp_errors" -gt 0 ]; then
    error "log capture pair policy check failed with $_lcp_errors error(s)"
    return 1
  fi
  say "log capture pair policy passed."
  return 0
}

# A repo-local .envrc is banned outright: direnv would inject a devShell env
# into every shell entering the tree, and once the store closure is garbage
# collected that env points at dead paths (builds and links fail). The scan
# walks the working tree because .envrc is gitignored, so a git-tracked-file
# list can never see it.
# ref: allow-and-deny-lists.instructions.md#A14 -- .envrc ban
run_envrc_ban_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _envrc_errors=0
  local _offenders=()
  local _f

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$(basename "$_f")" in
      .envrc) _offenders+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _offenders+=("${_f#./}")
    done < <(find . \( -path ./.git -o -path '*/.git' -o -path '*/vendor' \) -prune -o -name '.envrc' -type f -print0)
  fi

  if [ "${#_offenders[@]}" -gt 0 ]; then
    local _offender
    for _offender in "${_offenders[@]}"; do
      _envrc_errors=$((_envrc_errors + 1))
      error "envrc ban: '$_offender' exists; delete it (a repo-local .envrc would inject a devShell env at cd; see allow-and-deny-lists.instructions.md)"
    done
  fi

  if [ "$_envrc_errors" -gt 0 ]; then
    error "envrc ban policy check failed with $_envrc_errors error(s)"
    return 1
  fi
  say "envrc ban policy passed."
  return 0
}

# A prompt template is expanded by a substituter that understands only $1, $2,
# $@, $ARGUMENTS, ${N:-default}, and ${@:N}. A template without a slot silently
# discards everything typed after the command name, and a VS Code ${input:...}
# variable never expands outside VS Code.
# ref: allow-and-deny-lists.instructions.md#C5 -- pattern literals live in this file
run_prompt_template_contract() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  local _prompt_files=()
  local _errors=0 _f _prompt_count=0
  if $_has_args; then
    filter_scoped_files _prompt_files .agents/prompts '*.md' "${_files[@]}"
    filter_scoped_files _prompt_files src/users/default/agents/prompts '*.md' "${_files[@]}"
  else
    discover_files _prompt_files "$_repo_root" .agents/prompts '*.md'
    discover_files _prompt_files "$_repo_root" src/users/default/agents/prompts '*.md'
  fi

  for _f in "${_prompt_files[@]}"; do
    if [ -n "$_f" ]; then
      _prompt_count=$((_prompt_count + 1))
    fi
  done
  if ! $_has_args && [ "$_prompt_count" -eq 0 ]; then
    _errors=$((_errors + 1))
    error "no prompt templates found under .agents/prompts or src/users/default/agents/prompts"
  fi

  for _f in "${_prompt_files[@]}"; do
    [ -n "$_f" ] || continue
    if grep -qF "\${input:" "$_f"; then
      _errors=$((_errors + 1))
      error "$_f: VS Code \${input:...} cannot expand; use \$1, \$@, or \${N:-default}"
    fi
    if ! grep -qE '[$](ARGUMENTS|@|[0-9])|[$][{][0-9]+:-' "$_f"; then
      _errors=$((_errors + 1))
      error "$_f: no argument slot; text typed after the command is discarded"
    fi
  done

  local _policy="$_repo_root/src/users/default/agents/instructions/standing-orders.instructions.md"
  if [ -f "$_policy" ] &&
    grep -qF 'child-prompt-block:begin' "$_policy" &&
    ! grep -qF 'child-prompt-block:end' "$_policy"; then
    _errors=$((_errors + 1))
    error "$_policy: child-prompt-block markers are unbalanced"
  fi

  if [ "$_errors" -gt 0 ]; then
    error "prompt template contract failed with $_errors error(s)"
    return 1
  fi
  say "prompt template contract passed."
  return 0
}
