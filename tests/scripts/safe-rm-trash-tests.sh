#!/usr/bin/env bash
# Tests for the sandboxed Trash. Two facts have to hold together: the srt policy
# write-allows ~/.Trash, and ~/.safe-rm/config sets SAFE_RM_USE_APPLESCRIPT=no
# so safe-rm renames into that Trash with mv instead of scripting Finder. Either
# fact alone leaves a sandboxed rm broken: the policy without the config keeps
# the AppleScript route, which the sandbox blocks, and the config without the
# policy makes the mv fallback fail on a Trash the sandbox cannot write. The
# suite also checks the home.nix wiring, because a correct file at a path the
# activation never seeds fixes nothing.
#
# home.nix is read as text, not evaluated. The wiring is three attribute-level
# facts (the seed entry, the writable marking, the verify list), and those names
# and arguments are the only observable a suite can read without a full flake
# evaluation. Reading the selector out of the seed entry and resolving it here is
# what makes a typo fail: the resolution mirrors selectUserConfigFile in
# src/modules/lib/users-overlay.nix, first-level per-user entry before the
# default entry.
#
# Every family runs twice: once against the repo, and once against a copy with
# that family's fact removed, where the same predicate must fail. A predicate
# that cannot fail cannot vouch for anything, so the second run is what proves
# the first one is not vacuous.
#
# The ordering family asserts case-sensitive byte order over the whole allowWrite
# array, which is the only collation that is identical on every host: a
# locale-dependent sort produces a different array on a different machine. That
# assertion also covers a defect older than this suite: "~/dev" sat before
# "~/Library/Application Support/nucleus", which byte order puts first because
# "L" (0x4C) sorts before "d" (0x64). The same assertion would have caught that
# edit when it landed, and it catches an entry appended at the end.
# shellcheck disable=SC2329 # reason: the fact predicates below are dispatched indirectly through expect and expect_failure, which shellcheck cannot follow.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "the srt settings are read and edited with jq"

SETTINGS_REL="src/users/default/srt/settings.json"
CONFIG_REL="src/users/default/safe-rm/config"
HOME_NIX_REL="src/modules/home.nix"
# The Trash path srt matches. Escaped so the shell keeps the literal tilde: an
# unescaped one would expand to this shell's HOME and match nothing.
TRASH_ENTRY=\~/.Trash
# Home Manager expressions matched against the Nix source text. The dollar signs
# are escaped for the same reason: expanding them here would compare this
# shell's HOME against text that holds the expression.
SAFE_RM_ENTRY_PATH="path = \"\${resolvedHomeDirectory}/.safe-rm/config\";"
SAFE_RM_TARGET="\"\${config.home.homeDirectory}/.safe-rm/config\""

_tmp="$(mktemp -d)"
trap 'rm -rf -- "$_tmp"' EXIT

assert_eq() { # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3" "expected '$1', got '$2'"
  fi
}

# contains <haystack> <needle>
contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  *) return 1 ;;
  esac
}

# expect <name> <predicate> <args...>: the predicate must hold on the repo.
expect() { # <name> <predicate> <args...>
  local _name="$1"
  shift
  if "$@"; then
    assert_pass "$_name"
  else
    assert_fail "$_name" "predicate $* returned non-zero"
  fi
}

# expect_failure <name> <predicate> <args...>: the predicate must not hold on a
# copy whose fact was removed. A pass here is the anti-vacuity evidence.
expect_failure() { # <name> <predicate> <args...>
  local _name="$1"
  shift
  if "$@"; then
    assert_fail "$_name" "predicate $* still held after the fact was removed"
  else
    assert_pass "$_name"
  fi
}

# overlay_resolve <root> <config-name> <relative-path>: print the file the
# overlay selector would read under <root>. Mirrors selectUserConfigFile: the
# first path segment is looked up as a first-level entry, per-user tree before
# the default tree, and a per-user entry that exists without the requested file
# fails rather than falling back, exactly as the Nix selector throws.
overlay_resolve() { # <root> <config-name> <relative-path>
  local _root="$1" _config_name="$2" _relative="$3"
  local _first="${_relative%%/*}" _rest="" _dir _resolved=""
  if [ "$_first" != "$_relative" ]; then
    _rest="/${_relative#*/}"
  fi
  for _dir in "$_root"/src/users/*/; do
    case "$_dir" in
    */default/) continue ;;
    esac
    if [ -e "$_dir$_config_name/$_first" ]; then
      _resolved="$_dir$_config_name/$_first$_rest"
      break
    fi
  done
  if [ -z "$_resolved" ]; then
    _resolved="$_root/src/users/default/$_config_name/$_first$_rest"
  fi
  [ -e "$_resolved" ] || return 1
  printf '%s\n' "$_resolved"
}

# activation_block <root> <activation-name>: print one home.activation entry from
# its attribute line through the closing ''; terminator. Prints nothing when the
# entry is absent, which is how the red run reports a missing wiring fact.
activation_block() { # <root> <activation-name>
  local _home="$1/$HOME_NIX_REL"
  [ -f "$_home" ] || return 1
  awk -v name="$2" -v end="'';" '
    in_block {
      print
      if (index($0, end) > 0) exit
      next
    }
    index($0, "home.activation." name " =") > 0 {
      in_block = 1
      print
    }
  ' "$_home"
}

# The awk program behind symlink_entry and symlink_entry_without_line. It locates
# the managedSymlinkPaths entry whose path line matches `want` and bounds it by
# the entry's own braces, so a writable flag or a suppression comment is read
# from that entry and no other. An entry whose braces are not on their own lines
# is treated as absent: bounding it would otherwise spill into a neighbouring
# entry that carries the same flags, which is exactly the vacuous pass this
# suite exists to prevent. With `drop` empty the entry is printed; otherwise the
# whole file is printed with the lines matching `drop` removed from that entry.
# An absent or unbounded entry prints nothing in the first mode and the file
# unchanged in the second, so a missing fact reads as zero lines removed rather
# than as a mangled copy.
_ENTRY_AWK="$(
  cat <<'AWK'
  { line[NR] = $0 }
  index($0, want) > 0 && hit == 0 { hit = NR }
  END {
    start = 0
    stop = 0
    if (hit > 0) {
      s = hit
      while (s > 0) {
        if (line[s] ~ /^[[:space:]]*\{[[:space:]]*$/) { start = s; break }
        if (line[s] ~ /^[[:space:]]*\}[[:space:]]*$/) break
        s--
      }
      e = hit
      while (start > 0 && e <= NR) {
        if (line[e] ~ /^[[:space:]]*\}[[:space:]]*$/) { stop = e; break }
        if (line[e] ~ /^[[:space:]]*\{[[:space:]]*$/) break
        e++
      }
      if (stop == 0) start = 0
    }
    if (start == 0) {
      if (drop != "") {
        for (i = 1; i <= NR; i++) print line[i]
      }
      exit 0
    }
    if (drop == "") {
      for (i = start; i <= stop; i++) print line[i]
      exit 0
    }
    for (i = 1; i <= NR; i++) {
      if (i >= start && i <= stop && index(line[i], drop) > 0) continue
      print line[i]
    }
  }
AWK
)"

symlink_entry() { # <root>
  local _home="$1/$HOME_NIX_REL"
  [ -f "$_home" ] || return 1
  awk -v want="$SAFE_RM_ENTRY_PATH" -v drop="" "$_ENTRY_AWK" "$_home"
}

trash_is_write_allowed() { # <root>
  local _settings _count
  _settings="$(overlay_resolve "$1" "srt" "settings.json")" || return 1
  _count="$(jq -r --arg trash "$TRASH_ENTRY" '[.filesystem.allowWrite[] | select(. == $trash)] | length' "$_settings")" || return 1
  [ "$_count" = "1" ]
}

allow_write_is_sorted() { # <root>
  local _settings _listed _sorted
  # The entry has to be present as well: an array that never held it would sort
  # fine and say nothing about where it belongs.
  trash_is_write_allowed "$1" || return 1
  _settings="$(overlay_resolve "$1" "srt" "settings.json")" || return 1
  _listed="$(jq -r '.filesystem.allowWrite[]' "$_settings")" || return 1
  [ -n "$_listed" ] || return 1
  _sorted="$(printf '%s\n' "$_listed" | LC_ALL=C sort)" || return 1
  [ "$_listed" = "$_sorted" ]
}

# The directive text is asserted as well as the sourced value: safe-rm sources
# the file, so the value is what matters, and a second non-comment line would be
# a second directive nobody reviewed. The file carries comments only otherwise.
config_disables_applescript() { # <root>
  local _config _effective _value
  _config="$(overlay_resolve "$1" "safe-rm" "config")" || return 1
  [ -f "$_config" ] || return 1
  _effective="$(grep -vE '^[[:space:]]*(#|$)' "$_config")" || return 1
  [ "$_effective" = "export SAFE_RM_USE_APPLESCRIPT=no" ] || return 1
  _value="$(bash -c 'unset SAFE_RM_USE_APPLESCRIPT; . "$1"; printf "%s" "${SAFE_RM_USE_APPLESCRIPT-}"' _ "$_config")" || return 1
  [ "$_value" = "no" ]
}

selector_resolves() { # <root>
  local _block _selector _config_name _relative _resolved
  _block="$(activation_block "$1" "seed-safe-rm-config")"
  [ -n "$_block" ] || return 1
  _selector="$(grep -m1 -oE 'selectFile "[^"]*" "[^"]*"' <<<"$_block")" || return 1
  _config_name="$(awk -F'"' '{ print $2 }' <<<"$_selector")" || return 1
  _relative="$(awk -F'"' '{ print $4 }' <<<"$_selector")" || return 1
  _resolved="$(overlay_resolve "$1" "$_config_name" "$_relative")" || return 1
  [ -f "$_resolved" ]
}

seed_entry_uses_overlay() { # <root>
  local _block
  _block="$(activation_block "$1" "seed-safe-rm-config")"
  [ -n "$_block" ] || return 1
  contains "$_block" 'entryAfter [ "linkGeneration" ]' || return 1
  contains "$_block" 'seed-writable-symlink.sh' || return 1
  contains "$_block" "$SAFE_RM_TARGET" || return 1
  contains "$_block" 'selectFile "safe-rm"'
}

symlink_entry_is_writable() { # <root>
  local _entry
  _entry="$(symlink_entry "$1")"
  [ -n "$_entry" ] || return 1
  contains "$_entry" 'writable = true;' || return 1
  contains "$_entry" '# check-suppress:config-method:'
}

verify_list_names_seed() { # <root>
  local _block
  _block="$(activation_block "$1" "verify-managed-symlink-paths")"
  [ -n "$_block" ] || return 1
  contains "$_block" '"seed-safe-rm-config"'
}

# copy_fixture <dest-root>: copy the three files the predicates read. A source
# that does not exist stays missing in the copy, so the red run reports the real
# defect instead of dying inside the fixture.
copy_fixture() { # <dest-root>
  local _dest="$1" _rel
  mkdir -p "$_dest/src/users/default/srt" "$_dest/src/users/default/safe-rm" "$_dest/src/modules"
  for _rel in "$SETTINGS_REL" "$CONFIG_REL" "$HOME_NIX_REL"; do
    if [ -f "$REPO_ROOT/$_rel" ]; then
      cp "$REPO_ROOT/$_rel" "$_dest/$_rel"
    fi
  done
}

# Each removal below edits one fact and leaves the rest of the file intact. The
# guard on the source keeps a missing file missing, matching copy_fixture.
settings_without_trash() { # <src-root> <dest-root>
  if [ -f "$1/$SETTINGS_REL" ]; then
    jq --arg trash "$TRASH_ENTRY" '.filesystem.allowWrite |= map(select(. != $trash))' "$1/$SETTINGS_REL" >"$2/$SETTINGS_REL"
  fi
}

settings_with_trash_appended() { # <src-root> <dest-root>
  if [ -f "$1/$SETTINGS_REL" ]; then
    jq --arg trash "$TRASH_ENTRY" '.filesystem.allowWrite |= (map(select(. != $trash)) + [$trash])' "$1/$SETTINGS_REL" >"$2/$SETTINGS_REL"
  fi
}

config_without_directive() { # <src-root> <dest-root>
  if [ -f "$1/$CONFIG_REL" ]; then
    grep -v '^export SAFE_RM_USE_APPLESCRIPT=no$' "$1/$CONFIG_REL" >"$2/$CONFIG_REL"
  fi
}

home_with_selector_typo() { # <src-root> <dest-root>
  if [ -f "$1/$HOME_NIX_REL" ]; then
    sed 's|selectFile "safe-rm" "config"|selectFile "safe-rm" "conf"|' "$1/$HOME_NIX_REL" >"$2/$HOME_NIX_REL"
  fi
}

# block_without_line <activation-name> <literal> <src-root> <dest-root>: drop one
# line from inside that activation block only, so a look-alike line elsewhere
# cannot stand in for the missing fact.
block_without_line() { # <activation-name> <literal> <src-root> <dest-root>
  if [ -f "$3/$HOME_NIX_REL" ]; then
    awk -v name="$1" -v drop="$2" -v end="'';" '
      !in_block && index($0, "home.activation." name " =") > 0 { in_block = 1 }
      in_block && index($0, drop) > 0 { next }
      { print }
      in_block && index($0, end) > 0 { in_block = 0 }
    ' "$3/$HOME_NIX_REL" >"$4/$HOME_NIX_REL"
  fi
}

# symlink_entry_without_line <literal> <src-root> <dest-root>: drop one line from
# the ~/.safe-rm/config managedSymlinkPaths entry only.
symlink_entry_without_line() { # <literal> <src-root> <dest-root>
  if [ -f "$2/$HOME_NIX_REL" ]; then
    awk -v want="$SAFE_RM_ENTRY_PATH" -v drop="$1" "$_ENTRY_AWK" "$2/$HOME_NIX_REL" >"$3/$HOME_NIX_REL"
  fi
}

# expect_removal <name> <fixture-root> <relative-path> <removed-lines>: the copy
# must be the repo file with exactly that many lines gone. Without it an
# anti-vacuity case could pass because the copy came out empty or unedited, which
# would prove nothing about the predicate.
expect_removal() { # <name> <fixture-root> <relative-path> <removed-lines>
  local _diff="$_tmp/removal.diff" _removed=0
  if ! diff "$REPO_ROOT/$3" "$2/$3" >"$_diff"; then
    _removed="$(awk '/^</ { n++ } END { print n + 0 }' "$_diff")"
  fi
  assert_eq "$4" "$_removed" "$1"
}

section 1 "the srt policy write-allows the Trash"

expect "$TRASH_ENTRY is listed once in filesystem.allowWrite" trash_is_write_allowed "$REPO_ROOT"
copy_fixture "$_tmp/no-trash"
settings_without_trash "$REPO_ROOT" "$_tmp/no-trash"
assert_eq "0" "$(jq -r --arg trash "$TRASH_ENTRY" '[.filesystem.allowWrite[] | select(. == $trash)] | length' "$_tmp/no-trash/$SETTINGS_REL")" \
  "the no-trash copy really lost the entry"
expect_failure "anti-vacuity: without the ~/.Trash entry the write check fails" trash_is_write_allowed "$_tmp/no-trash"

section 2 "allowWrite keeps case-sensitive byte order"

expect "filesystem.allowWrite is sorted case-sensitively" allow_write_is_sorted "$REPO_ROOT"
copy_fixture "$_tmp/trash-appended"
settings_with_trash_appended "$REPO_ROOT" "$_tmp/trash-appended"
assert_eq "$TRASH_ENTRY" "$(jq -r '.filesystem.allowWrite[-1]' "$_tmp/trash-appended/$SETTINGS_REL")" \
  "the appended copy really ends with ~/.Trash"
expect_failure "anti-vacuity: an appended ~/.Trash breaks the order check" allow_write_is_sorted "$_tmp/trash-appended"

section 3 "safe-rm is told to skip AppleScript"

expect "sourcing the config yields SAFE_RM_USE_APPLESCRIPT=no" config_disables_applescript "$REPO_ROOT"
copy_fixture "$_tmp/no-directive"
config_without_directive "$REPO_ROOT" "$_tmp/no-directive"
expect_removal "the no-directive copy lost exactly the export line" "$_tmp/no-directive" "$CONFIG_REL" 1
expect_failure "anti-vacuity: without the directive the sourced value check fails" config_disables_applescript "$_tmp/no-directive"

section 4 "the activation selector resolves to a real file"

expect "selectFile in seed-safe-rm-config resolves under src/users" selector_resolves "$REPO_ROOT"
copy_fixture "$_tmp/selector-typo"
home_with_selector_typo "$REPO_ROOT" "$_tmp/selector-typo"
expect_removal "the selector copy lost exactly the original selector line" "$_tmp/selector-typo" "$HOME_NIX_REL" 1
expect_failure "anti-vacuity: a selector typo stops resolving" selector_resolves "$_tmp/selector-typo"

section 5 "the seed entry deploys the config through the overlay"

expect "seed-safe-rm-config seeds ~/.safe-rm/config after linkGeneration" seed_entry_uses_overlay "$REPO_ROOT"
copy_fixture "$_tmp/no-seeder"
block_without_line "seed-safe-rm-config" 'seed-writable-symlink.sh' "$REPO_ROOT" "$_tmp/no-seeder"
expect_removal "the no-seeder copy lost exactly the seeder line" "$_tmp/no-seeder" "$HOME_NIX_REL" 1
expect_failure "anti-vacuity: without the seeder call the seed entry check fails" seed_entry_uses_overlay "$_tmp/no-seeder"

section 6 "the managed symlink entry is writable and annotated"

expect "the managed safe-rm config entry is writable and carries the config-method suppression" symlink_entry_is_writable "$REPO_ROOT"
copy_fixture "$_tmp/not-writable"
symlink_entry_without_line 'writable = true;' "$REPO_ROOT" "$_tmp/not-writable"
expect_removal "the not-writable copy lost exactly the writable flag" "$_tmp/not-writable" "$HOME_NIX_REL" 1
expect_failure "anti-vacuity: without writable = true the entry check fails" symlink_entry_is_writable "$_tmp/not-writable"
copy_fixture "$_tmp/no-suppression"
symlink_entry_without_line 'check-suppress:config-method:' "$REPO_ROOT" "$_tmp/no-suppression"
expect_removal "the no-suppression copy lost exactly the comment line" "$_tmp/no-suppression" "$HOME_NIX_REL" 1
expect_failure "anti-vacuity: without the suppression comment the entry check fails" symlink_entry_is_writable "$_tmp/no-suppression"

section 7 "the post-seed verify list covers the new entry"

expect "the verify activation runs after seed-safe-rm-config" verify_list_names_seed "$REPO_ROOT"
copy_fixture "$_tmp/verify-missing"
block_without_line "verify-managed-symlink-paths" '"seed-safe-rm-config"' "$REPO_ROOT" "$_tmp/verify-missing"
expect_removal "the verify copy lost exactly the list entry" "$_tmp/verify-missing" "$HOME_NIX_REL" 1
expect_failure "anti-vacuity: without the list entry the verify check fails" verify_list_names_seed "$_tmp/verify-missing"

finish_tests
