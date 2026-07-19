# macOS-only iCloud exclusion hooks.
# WHY macOS-only: com.apple.fileprovider.ignore#P is a macOS FileProvider
# xattr with no equivalent on NixOS/Windows.
#
# Tokens: __ICLOUD_EXCLUDED_NAMES__, __ICLOUD_MANAGED_ROOTS__
#
# Trigger paths:
#   1) chpwd hook: entering directories performs a best-effort recursive
#      pass under iCloud-managed roots.
#   2) mkdir wrapper: newly created matching directories are marked
#      immediately.
#   3) precmd hook: after each command, checks immediate children of
#      $PWD (depth 1) for newly created excluded dirs.  This catches
#      tools like npm install, git clone, pip install that create
#      directories via syscalls without using mkdir.
#
# Existing directories are also covered by the activation-time recursive
# pass in modules/macos.nix.

typeset -ga __nucleus_icloud_excluded_names=( __ICLOUD_EXCLUDED_NAMES__ )

__nucleus_is_icloud_managed_path() {
  local candidate_path="$1"
  local root
  for root in __ICLOUD_MANAGED_ROOTS__; do
    [[ -z "$root" ]] && continue
    if [[ "$candidate_path" == "$HOME/$root" || "$candidate_path" == "$HOME/$root/"* ]]; then
      return 0
    fi
  done
  return 1
}

__nucleus_check_icloud_exclusion() {
  local target_path="$1"
  local normalized_path
  local current_mark
  local target_name

  if [[ "$target_path" == /* ]]; then
    normalized_path="$target_path"
  else
    normalized_path="$PWD/$target_path"
  fi
  normalized_path="${normalized_path%/}"

  __nucleus_is_icloud_managed_path "$normalized_path" || return 0

  target_name=$(basename "$normalized_path")

  for excluded in "${__nucleus_icloud_excluded_names[@]}"; do
    if [[ "$target_name" == "$excluded" ]]; then
      # Missing xattr is expected for newly created paths, so probe the
      # value quietly and only log when we actually mutate state.
      current_mark="$(
        /usr/bin/xattr -p com.apple.fileprovider.ignore#P "$normalized_path" 2>/dev/null
        # undoc-supp: xattr may not be set yet on newly created path; absence is not an error — the check below gates on value "1".
      )" || true
      if [[ "$current_mark" == "1" ]]; then
        return 0
      fi

      if /usr/bin/xattr -w com.apple.fileprovider.ignore#P 1 "$normalized_path"; then
        echo "shell: iCloud exclusion marked $normalized_path" >&2
      else
        echo "shell: failed to mark iCloud exclusion for $normalized_path" >&2
      fi
      return 0
    fi
  done
  return 0
}

__nucleus_mark_icloud_exclusions_under() {
  local root_path="$1"

  __nucleus_is_icloud_managed_path "$root_path" || return 0
  [[ "${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0

  # Build find predicate with -prune to stop recursion into excluded dirs.
  # Pattern: ( -name A -prune -o -name B -prune -o ... -o -type d )
  # This avoids descending into node_modules, .venv, etc. during interactive
  # chpwd hook, which would freeze the terminal for 10+ seconds on large repos.
  local -a __icloud_find_args
  __icloud_find_args=()
  local __icloud_n=0
  local __icloud_name
  for __icloud_name in "${__nucleus_icloud_excluded_names[@]}"; do
    if [[ $__icloud_n -eq 0 ]]; then
      __icloud_find_args+=( "(" "-name" "$__icloud_name" "-prune" )
    else
      __icloud_find_args+=( "-o" "-name" "$__icloud_name" "-prune" )
    fi
    __icloud_n=$(( __icloud_n + 1 ))
  done
  # Final -type d to match any non-excluded directory.
  __icloud_find_args+=( "-o" "-type" "d" ")" )

  local __candidate
  while IFS= read -r __candidate; do
    __nucleus_check_icloud_exclusion "$__candidate"
  done < <(/usr/bin/find "$root_path" "${__icloud_find_args[@]}" 2>/dev/null)

  return 0
}

__nucleus_check_icloud_exclusions_on_pwd_change() {
  [[ "${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0
  __nucleus_mark_icloud_exclusions_under "$PWD"
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd __nucleus_check_icloud_exclusions_on_pwd_change
__nucleus_check_icloud_exclusions_on_pwd_change

# Lightweight precmd check: scans only immediate children of $PWD (-maxdepth 1)
# so tools that create excluded directories without mkdir (npm install,
# git clone, pip install, etc.) get marked promptly.  Unlike the chpwd
# hook, this must be fast — it runs after every command.
__nucleus_check_icloud_exclusions_immediate() {
  [[ "${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0
  local __candidate
  while IFS= read -r __candidate; do
    __nucleus_check_icloud_exclusion "$__candidate"
  done < <(/usr/bin/find "$PWD" -maxdepth 1 -type d 2>/dev/null)
}

add-zsh-hook precmd __nucleus_check_icloud_exclusions_immediate

# Override mkdir to check for excluded directories after creation.
mkdir() {
  /bin/mkdir "$@"
  local _mkdir_status=$?

  # Only process if mkdir succeeded and we're not in dry-run mode.
  if [[ $_mkdir_status -eq 0 ]]; then
    for arg in "$@"; do
      # Skip option flags (starting with -)
      if [[ ! "$arg" =~ ^- ]]; then
        # Check if the path exists (was created successfully)
        if [[ -d "$arg" ]]; then
          __nucleus_check_icloud_exclusion "$arg"
        fi
      fi
    done
  fi

  return $_mkdir_status
}
