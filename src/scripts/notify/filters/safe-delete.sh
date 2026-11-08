#!/usr/bin/env bash
# safe-delete filter: denies the spellings that bypass the safe-delete layer and
# applies settings.unproven to a deletion command whose redirect it cannot prove.
#
#   filters/safe-delete.sh --settings <json> --command <text>
#   stdout: decision<TAB>rule<TAB>reason
#
# Rule families, name for name with the three branches of the retired guard, plus
# the redirect question:
#   native-path       an absolute or relative path to the delete binary
#   escaped-spelling  a backslash-escaped deletion command, which skips the alias
#   cmd-shell         cmd.exe, which is never allowed on any host
#   proven-redirect   a deletion command whose word resolves to the managed wrapper
#   unproven-redirect a deletion command whose redirect is unproven, which is
#                     treated as not redirected
#   no-match          nothing to gate
#
# An unproven redirect is treated as not redirected: settings.unproven says what
# that gets, so deny (the registry default) blocks the command, route puts it to
# the approval sources, and allow lets it through. A redirect is proven only when
# the deletion word resolves to the managed wrapper this host deploys, so a PATH
# that reaches a plain binary, a wrapper that is absent, and a wrapper that is not
# the managed deployment all read as unproven.
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

if ! _sd_unproven="$(jq -r '.unproven // "deny"' <<<"$_sd_settings")"; then
  printf 'ask\tfilter-error\tsettings are not valid JSON\n'
  exit 0
fi

# WHY the guard's three branches verbatim: they are the spellings that reach a
# delete without passing the interactive alias or the PATH shim, so a filter that
# gated fewer of them would silently reopen a documented bypass.
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

# A deletion command as the invoked word, optionally behind sudo. The pattern
# anchors on a command separator, so the same verb in an argument position or
# inside quotes does not match.
_sd_verb_re='(^|[;&|(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)([[:space:]]|$)'
if [[ $_sd_command =~ $_sd_verb_re ]]; then
  _sd_verb="${BASH_REMATCH[3]}"

  # The managed wrapper for this verb: the home.file entry src/modules/shell/default.nix
  # deploys at ~/.local/bin/<verb>. It is a symlink into the Nix store, and that
  # shape is what separates it from a plain binary left at the same path.
  _sd_wrapper=""
  if [ -n "${HOME-}" ]; then
    _sd_wrapper="$HOME/.local/bin/$_sd_verb"
  fi

  # WHY sh -c: `command -v` is a shell's own PATH lookup, so the answer is the one
  # the calling shell gets from the PATH this process inherited. An alias or a
  # function is invisible to a child shell, which is why only a PATH answer can be
  # proven from here.
  _sd_resolved=""
  if ! _sd_resolved="$(sh -c 'command -v "$1"' sh "$_sd_verb")"; then
    _sd_resolved=""
  fi

  if [ -n "$_sd_wrapper" ] && [ "$_sd_resolved" = "$_sd_wrapper" ] && [ -L "$_sd_wrapper" ]; then
    printf 'allow\tproven-redirect\t%s\n' "deletion command: $_sd_verb resolves to the managed safe-delete wrapper at $_sd_wrapper"
    exit 0
  fi

  if [ -z "$_sd_wrapper" ]; then
    _sd_why="$_sd_verb has no managed wrapper to compare against because HOME is unset"
  elif [ -z "$_sd_resolved" ]; then
    _sd_why="$_sd_verb does not resolve on PATH"
  elif [ "$_sd_resolved" = "$_sd_wrapper" ]; then
    _sd_why="$_sd_verb resolves to $_sd_wrapper, which is a plain file rather than the managed symlink"
  else
    _sd_why="$_sd_verb resolves to $_sd_resolved, not the managed safe-delete wrapper at $_sd_wrapper"
  fi
  case "$_sd_unproven" in
  deny)
    printf 'deny\tunproven-redirect\t%s\n' "deletion command: $_sd_why, so it is treated as not redirected. Use shell-safe-rm or rip2 instead."
    exit 0
    ;;
  route)
    printf 'ask\tunproven-redirect\t%s\n' "deletion command: $_sd_why, so it is treated as not redirected and the harness prompts"
    exit 0
    ;;
  allow)
    printf 'allow\tunproven-redirect\t%s\n' "deletion command: $_sd_why, and settings.unproven allows an unproven redirect"
    exit 0
    ;;
  esac
  printf 'deny\tunproven-redirect\t%s\n' "deletion command: $_sd_why, and settings.unproven is '$_sd_unproven' rather than deny, route, or allow, so the unproven redirect is denied. Use shell-safe-rm or rip2 instead."
  exit 0
fi

printf 'allow\tno-match\t%s\n' "no deletion command"
