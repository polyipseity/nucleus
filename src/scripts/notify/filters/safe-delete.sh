#!/usr/bin/env bash
# safe-delete filter: denies the spellings that bypass the safe-delete layer and
# asks about a deletion command whose safe redirect is not proven.
#
#   filters/safe-delete.sh --settings <json> --command <text>
#   stdout: decision<TAB>rule<TAB>reason
#
# Rule families, name for name with the three branches of the retired guard, plus
# the redirect question:
#   native-path       an absolute or relative path to the delete binary
#   escaped-spelling  a backslash-escaped deletion command, which skips the alias
#   cmd-shell         cmd.exe, which is never allowed on any host
#   unproven-redirect a deletion command with no proof yet that it reaches the
#                     safe alternative
#   no-match          nothing to gate
#
# settings.unproven (deny | route | allow) says what to do with a command whose
# redirect is unproven.
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

# A deletion command as the invoked word, optionally behind sudo. Quoted
# occurrences match too, which is safe here because the outcome is a prompt, not
# a denial.
if printf '%s' "$_sd_command" |
  grep -Eq '(^|[;&|(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)([[:space:]]|$)'; then
  # TODO: Task 3 -- the redirect proof decides here. Until it exists only `allow`
  # is honoured, so the registry default `deny` cannot block a command whose
  # redirect was never checked; `deny` and `route` therefore ask for now.
  case "$_sd_unproven" in
  allow)
    printf 'allow\tunproven-redirect\t%s\n' "deletion command: the safe redirect is unproven and settings.unproven allows it"
    exit 0
    ;;
  esac
  printf 'ask\tunproven-redirect\t%s\n' "deletion command: the safe redirect is unproven, so the harness prompts"
  exit 0
fi

printf 'allow\tno-match\t%s\n' "no deletion command"
