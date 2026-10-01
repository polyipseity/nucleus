# WHY macOS-only: com.apple.fileprovider.ignore#P is a macOS FileProvider xattr
# with no equivalent on NixOS/Windows.
#
# __UPPERCASE_TOKEN__ variables below are substituted via Nix replaceStrings at
# build time.

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
      # check-suppress:suppression_doc: xattr may not be set yet on newly created path; absence is not an error -- the check below gates on value "1".
      current_mark="$(
        /usr/bin/xattr -p com.apple.fileprovider.ignore#P "$normalized_path" 2>/dev/null
      )" || true
      if [[ "$current_mark" == "1" ]]; then
        return 0
      fi

      if /usr/bin/xattr -w com.apple.fileprovider.ignore#P 1 "$normalized_path"; then
        echo "shell: iCloud exclusion marked $normalized_path" >&2
      else
        echo "shell: error: failed to mark iCloud exclusion for $normalized_path" >&2
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

  # WHY -prune: descending into node_modules and .venv freezes the interactive
# chpwd hook for 10+ seconds on a large repo.
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

# WHY depth 1: npm install, git clone and pip install create directories
# through syscalls that bypass the mkdir wrapper, and this runs after every
# command, so it must stay cheap.
__nucleus_check_icloud_exclusions_immediate() {
  [[ "${#__nucleus_icloud_excluded_names[@]}" -gt 0 ]] || return 0
  local __candidate
  while IFS= read -r __candidate; do
    __nucleus_check_icloud_exclusion "$__candidate"
  done < <(/usr/bin/find "$PWD" -maxdepth 1 -type d 2>/dev/null)
}

add-zsh-hook precmd __nucleus_check_icloud_exclusions_immediate

mkdir() {
  /bin/mkdir "$@"
  local _mkdir_status=$?

  if [[ $_mkdir_status -eq 0 ]]; then
    for arg in "$@"; do
      # Skip option flags (starting with -)
      if [[ ! "$arg" =~ ^- ]]; then
        if [[ -d "$arg" ]]; then
          __nucleus_check_icloud_exclusion "$arg"
        fi
      fi
    done
  fi

  return $_mkdir_status
}
