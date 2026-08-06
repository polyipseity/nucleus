# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "vm-manifest-regression" 25 "VM manifest regression gate" run_25_vm_manifest_regression

run_25_vm_manifest_regression() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s25_errors=0
  # Exclude both step files: their source contains every guard literal below.
  local _s25_self_sh _s25_self_ps1
  _s25_self_sh="$(basename "${BASH_SOURCE[0]}")"
  _s25_self_ps1="25-vm-manifest-regression.ps1"

  # Scope: production code under src/ and scripts/ with code extensions —
  # same scope as the legacy-token gate (step 23). .md prose, tests/ fixtures,
  # and the manifest/schema (VMs.json, VMs.schema.json) are excluded by scope.
  local _scan_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
        src/*|scripts/*)
          case "$_f" in
            *.ps1|*.sh|*.zsh|*.nix|*.yml)
              case "$(basename "$_f")" in
                "$_s25_self_sh"|"$_s25_self_ps1") : ;;
                *) _scan_files+=("$_f") ;;
              esac
              ;;
          esac
          ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      case "$_f" in
        *.ps1|*.sh|*.zsh|*.nix|*.yml) _scan_files+=("$_f") ;;
      esac
    done < <(find src scripts -type f \( -name '*.ps1' -o -name '*.sh' -o -name '*.zsh' -o -name '*.nix' -o -name '*.yml' \) -not -name "$_s25_self_sh" -not -name "$_s25_self_ps1" -print0)
    mapfile -t _scan_files < <(printf '%s\n' "${_scan_files[@]}" | filter_gitignored)
  fi

  # G2 scope — VM backend code under src/scripts + src/hosts + scripts/vm.*,
  # minus the two size parsers whose factor tables legitimately define GiB.
  local _g2_files=()
  for _f in "${_scan_files[@]}"; do
    case "$_f" in
      src/scripts/*|src/hosts/*|scripts/vm.sh|scripts/vm.ps1)
        case "$_f" in
          src/scripts/lib/size.sh|src/hosts/Windows/modules/SizeStrings.ps1) : ;;
          *) _g2_files+=("$_f") ;;
        esac
        ;;
    esac
  done

  # G3/G6 scope — all files minus the three size parsers (they define the grammar).
  local _g3_files=()
  for _f in "${_scan_files[@]}"; do
    case "$_f" in
      src/scripts/lib/size.sh|src/hosts/Windows/modules/SizeStrings.ps1|src/modules/lib/size.nix) : ;;
      *) _g3_files+=("$_f") ;;
    esac
  done

  # _s25_gate — report each grep -nH hit (minus allow-lines) as a violation.
  # usage: _s25_gate <label> <allow-regex> <file...>
  _s25_gate() {
    local _label="$1" _allow="$2"; shift 2
    local _v
    while IFS= read -r _v; do
      _s25_errors=$((_s25_errors + 1))
      error "$_v"
    done < <(grep -nH -E "$_label" "$@" | grep -vE "${_allow:-^\$}")
  }

  # G1: no byte-count manifest property refs (ramBytes/diskBytes) — production
  # consumers must use the parsed .ram/.diskSize values.
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    _s25_gate '\.ramBytes|\.diskBytes|"ramBytes"|"diskBytes"' '' "${_scan_files[@]}"
  fi

  # G2: no binary GiB literals (524288/536870912/1073741824) outside the size
  # parser factor tables and the documented tart/Packer whole-GiB adapter
  # (vm.sh `_mem_gib` line — see its WHY comment).
  if [ "${#_g2_files[@]}" -gt 0 ]; then
    _s25_gate '524288|536870912|1073741824' '_mem_gib=' "${_g2_files[@]}"
  fi

  # G3: no 1048576 (1 MiB) outside the three size parser files.
  if [ "${#_g3_files[@]}" -gt 0 ]; then
    _s25_gate '1048576' '' "${_g3_files[@]}"
  fi

  # G4: no `.display` manifest property refs (`.displayName` is a different,
  # unrelated field). `power.sleep.display` (macOS power management) is allowed.
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    _s25_gate '\.display([^A-Za-z0-9_]|$)|vm\.display([^A-Za-z0-9_]|$)|"display"' 'power\.sleep\.display' "${_scan_files[@]}"
  fi

  # G5: no hard-coded host-side ports — guest port forwards must come from the
  # manifest portForwards (22000-22099 host refs belong only in manifest/tests/docs).
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    _s25_gate 'hostfwd=tcp::220[0-9]{2}|localhost:220[0-9]{2}|-p 220[0-9]{2}|::220[0-9]{2}-:|<integer>220[0-9]{2}</integer>' '' "${_scan_files[@]}"
  fi

  # G6: no invalid suffix forms KB/KiB — except the parser doc comments (excluded
  # by scope above) and the pre-existing health-check message (df -Pk reports 1K
  # blocks, i.e. KiB).
  if [ "${#_g3_files[@]}" -gt 0 ]; then
    _s25_gate '(^|[^A-Za-z])KB([^A-Za-z]|$)|(^|[^A-Za-z])KiB([^A-Za-z]|$)' 'KiB available' "${_g3_files[@]}"
  fi

  # G7: no unit-in-identifier names (mib/gib) — except the sanctioned tart/Packer
  # adapter vars (_disk_gib/_mem_gib/disk_size_gib/memory_gib) and the scripts/vm.sh
  # decimal display rounding (ram_gib, pinned by vm-setup-tests.nix).
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    _s25_gate 'mib|gib' '_disk_gib|_mem_gib|ram_gib|disk_size_gib|memory_gib' "${_scan_files[@]}"
  fi

  if [ "$_s25_errors" -gt 0 ]; then
    say "  VM size/port references must follow the manifest contract — see .agents/instructions/vm-management.instructions.md (suffix grammar) and src/modules/VMs.schema.json (portForwards)."
    return 1
  fi

  say "no VM manifest contract regressions found."
  return 0
}
