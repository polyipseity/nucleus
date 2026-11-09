#!/usr/bin/env bash
# safe-delete filter: denies the spellings that bypass the safe-delete layer and
# applies settings.unproven to a deletion command whose redirect it cannot prove.
#
#   filters/safe-delete.sh --settings <json> --command <text>
#   stdout: decision<TAB>rule<TAB>reason
#
# Rule families, name for name with the three branches of safe-delete-guard, plus
# the redirect question. No hook file registers that guard any more: what remains is
# the PATH command safe-delete-guard on POSIX and the safe-delete-guard.cmd shim on
# Windows, which a caller can still name directly.
#   native-path       an absolute or relative path to the delete binary
#   escaped-spelling  a backslash-escaped deletion command, which skips the alias
#   cmd-shell         cmd.exe, which is never allowed on any host
#   proven-redirect   a deletion command whose word resolves to the managed wrapper
#   unproven-redirect a deletion command whose redirect is unproven, which is
#                     treated as not redirected
#   no-match          nothing to gate
#
# An unproven redirect is treated as not redirected: settings.unproven says what
# that gets, so ask (the registry default) puts it to the approval sources, deny
# blocks the command, and allow lets it through. A redirect is proven only when
# the deletion word resolves to the wrapper home.file deploys, so a PATH that
# reaches a plain binary, a wrapper that is absent, a wrapper linked anywhere else,
# and a word behind sudo all read as unproven.
set -euo pipefail

_sd_settings='{}'
_sd_command=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --settings)
    _sd_settings="${2-}"
    shift 2
    ;;
  --command)
    _sd_command="${2-}"
    shift 2
    ;;
  *)
    printf 'ask\tfilter-error\tunknown argument: %s\n' "$1"
    exit 0
    ;;
  esac
done

if ! _sd_unproven="$(jq -r '.unproven // "ask"' <<<"$_sd_settings")"; then
  printf 'ask\tfilter-error\tsettings are not valid JSON\n'
  exit 0
fi

# WHY the guard's three branches verbatim: they are the spellings that reach a
# delete without passing the interactive alias or the PATH shim, so a filter that
# gated fewer of them would silently reopen a documented bypass.
# WHY nocasematch across the three families: the verb test below folds case, so an
# uppercase word is a deletion, and a fold that stopped at the verb would let `\RM`,
# `./RM`, and `/usr/BIN/rm` slip the families and answer no-match, which reads as
# allow. The fold is scoped to these cases, so the settings.unproven comparison
# below stays case-sensitive.
shopt -s nocasematch
case "$_sd_command" in
*/bin/rm* | ./*rm*)
  printf 'deny\tnative-path\t%s\n' "native rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead."
  exit 0
  ;;
esac
case "$_sd_command" in
*'\rm'* | *'\del'* | *'\rd'* | *'\erase'* | *'\ri'* | *'\unlink'* | *'\shred'*)
  printf 'deny\tescaped-spelling\t%s\n' "a backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead."
  exit 0
  ;;
esac
case "$_sd_command" in
*cmd.exe* | *" cmd "*)
  printf 'deny\tcmd-shell\t%s\n' "cmd.exe is not allowed. Use pwsh instead."
  exit 0
  ;;
esac
# WHY a fold close here as well as in the verb block: this one closes the fold the
# three families opened, so the settings.unproven comparison stays case-sensitive
# no matter where that block sits relative to it. The verb block opens and closes
# its own fold, because the proof below resolves the word as typed.
shopt -u nocasematch

# A deletion command as the invoked word, optionally behind sudo. The pattern
# anchors on a command separator, so the same verb in an argument position or
# inside quotes does not match.
_sd_verb_re='(^|[;&|(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)([[:space:]]|$)'
# WHY nocasematch: PowerShell folds case for every one of these words, so `DEL` and
# `Remove-Item` are deletions on the other twin, and a lowercase-only test would let
# the same bytes answer no-match, which reads as allow. The proof still resolves the
# word as typed, because a POSIX PATH lookup is case-sensitive.
_sd_is_deletion=false
shopt -s nocasematch
if [[ $_sd_command =~ $_sd_verb_re ]]; then
  _sd_is_deletion=true
  _sd_verb="${BASH_REMATCH[3]}"
  _sd_sudo="${BASH_REMATCH[2]}"
fi
shopt -u nocasematch
if [ "$_sd_is_deletion" = true ]; then

  # The wrapper home.file deploys for this verb (src/modules/shell/default.nix):
  # ~/.local/bin/<verb> linked into home-manager's file tree. The link and its
  # target are both checked, so a link the user pointed elsewhere is no proof.
  _sd_wrapper=""
  if [ -n "${HOME-}" ]; then
    _sd_wrapper="$HOME/.local/bin/$_sd_verb"
  fi

  _sd_resolved=""
  _sd_target=""
  _sd_why=""
  if [ -n "$_sd_sudo" ]; then
    # WHY no proof behind sudo: sudo runs the word in an environment this
    # repository does not manage (the tree carries no sudoers PATH policy), so the
    # caller's PATH says nothing about what `sudo $_sd_verb` reaches.
    _sd_why="$_sd_verb runs behind sudo, whose PATH this repository does not manage"
  elif [ -z "$_sd_wrapper" ]; then
    _sd_why="$_sd_verb has no managed wrapper to compare against because HOME is unset"
  else
    # WHY sh -c: `command -v` is a shell's own PATH lookup, so the answer is the
    # one the calling shell gets from the PATH this process inherited. An alias or
    # a function is invisible to a child shell, which is why only a PATH answer can
    # be proven from here.
    if ! _sd_resolved="$(sh -c 'command -v "$1"' sh "$_sd_verb")"; then
      _sd_resolved=""
    fi
    if [ "$_sd_resolved" = "$_sd_wrapper" ] && [ -L "$_sd_wrapper" ]; then
      # WHY the target, not just the link: home-manager links the wrapper into its
      # `home-manager-files` derivation, so a link to any other executable (a plain
      # /bin/rm, for one) is a wrapper swapped out, not the deployment.
      if ! _sd_target="$(readlink "$_sd_wrapper")"; then
        _sd_target=""
      fi
      case "$_sd_target" in
      *home-manager-files/.local/bin/"$_sd_verb")
        printf 'allow\tproven-redirect\t%s\n' "deletion command: $_sd_verb resolves to the home-manager safe-delete wrapper at $_sd_wrapper"
        exit 0
        ;;
      esac
    fi
    if [ -z "$_sd_resolved" ]; then
      _sd_why="$_sd_verb does not resolve on PATH"
    elif [ "$_sd_resolved" != "$_sd_wrapper" ]; then
      _sd_why="$_sd_verb resolves to $_sd_resolved, not the managed safe-delete wrapper at $_sd_wrapper"
    elif [ ! -L "$_sd_wrapper" ]; then
      _sd_why="$_sd_verb resolves to $_sd_wrapper, which is a plain file rather than the managed symlink"
    elif [ -z "$_sd_target" ]; then
      _sd_why="$_sd_wrapper is a symlink that does not resolve"
    else
      _sd_why="$_sd_wrapper is a symlink to $_sd_target, not the home-manager wrapper for $_sd_verb"
    fi
  fi
  case "$_sd_unproven" in
  deny)
    printf 'deny\tunproven-redirect\t%s\n' "deletion command: $_sd_why, so it is treated as not redirected. Use shell-safe-rm or rip2 instead, or set harness-filters.json safe-delete.settings.unproven to ask or allow."
    exit 0
    ;;
  ask)
    printf 'ask\tunproven-redirect\t%s\n' "deletion command: $_sd_why, so it is treated as not redirected and the harness prompts"
    exit 0
    ;;
  allow)
    printf 'allow\tunproven-redirect\t%s\n' "deletion command: $_sd_why, and settings.unproven allows an unproven redirect"
    exit 0
    ;;
  esac
  printf 'deny\tunproven-redirect\t%s\n' "deletion command: $_sd_why, and settings.unproven is '$_sd_unproven' rather than deny, ask, or allow, so the unproven redirect is denied. Use shell-safe-rm or rip2 instead."
  exit 0
fi

printf 'allow\tno-match\t%s\n' "no deletion command"
