<#
.SYNOPSIS
  safe-delete filter: denies the spellings that bypass the safe-delete layer and
  asks about a deletion command whose safe redirect is not proven.

.DESCRIPTION
  Windows twin of filters/safe-delete.sh.

    filters\safe-delete.ps1 --settings <json> --command <text>
    stdout: decision<TAB>rule<TAB>reason

  Rule families, name for name with the three branches of the retired guard, plus
  the redirect question:

    native-path        an absolute or relative path to the delete binary
    escaped-spelling   a backslash-escaped deletion command, which skips the alias
    cmd-shell          cmd.exe, which is never allowed on any host
    unproven-redirect  a deletion command with no proof yet that it reaches the
                       safe alternative
    no-match           nothing to gate

  settings.unproven (deny | route | allow) says what to do with a command whose
  redirect is unproven.

.PARAMETER Settings
  Filter settings as a JSON object.

.PARAMETER Command
  Shell command under test.

.EXAMPLE
  pwsh -NoProfile -File safe-delete.ps1 --settings '{"unproven":"deny"}' --command '/bin/rm -rf x'

.NOTES
  Exit codes: always 0.  A filter states its verdict on stdout, so the runner
  distinguishes a broken filter from a decision by the line, not by the status.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Settings = '{}',

  [Parameter(Position = 1)]
  [string]$Command = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$unproven = 'deny'
try {
  $parsed = ConvertFrom-Json -InputObject $Settings -AsHashtable
  if ($parsed -is [hashtable] -and $parsed.ContainsKey('unproven')) { $unproven = [string]$parsed['unproven'] }
}
catch {
  Write-Output ("ask`tfilter-error`tsettings are not valid JSON")
  exit 0
}

# WHY the guard's three branches verbatim: they are the spellings that reach a
# delete without passing the interactive alias or the PATH shim, so a filter that
# gated fewer of them would silently reopen a documented bypass.
if ($Command -like '*/bin/rm*' -or $Command -like './*rm*') {
  Write-Output ("deny`tnative-path`tnative rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.")
  exit 0
}
$escaped = @('\rm', '\del', '\rd', '\erase', '\ri', '\unlink', '\shred')
foreach ($spelling in $escaped) {
  if ($Command.Contains($spelling)) {
    Write-Output ("deny`tescaped-spelling`ta backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.")
    exit 0
  }
}
if ($Command -like '*cmd.exe*' -or $Command -like '* cmd *') {
  Write-Output ("deny`tcmd-shell`tcmd.exe is not allowed. Use pwsh instead.")
  exit 0
}

# A deletion command as the invoked word, optionally behind sudo. Quoted
# occurrences match too, which is safe here because the outcome is a prompt, not
# a denial.
$deletion = '(^|[;&|(]|&&|\|\|)\s*(sudo\s+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)(\s|$)'
if ($Command -cmatch $deletion) {
  # TODO: Task 3 -- the redirect proof decides here. Until it exists only `allow`
  # is honoured, so the registry default `deny` cannot block a command whose
  # redirect was never checked; `deny` and `route` therefore ask for now.
  # WHY -ceq: the POSIX twin matches the setting with a case-sensitive case, so a
  # value spelled 'Allow' must not enable the redirect exemption on one host only.
  if ($unproven -ceq 'allow') {
    Write-Output ("allow`tunproven-redirect`tdeletion command: the safe redirect is unproven and settings.unproven allows it")
    exit 0
  }
  Write-Output ("ask`tunproven-redirect`tdeletion command: the safe redirect is unproven, so the harness prompts")
  exit 0
}

Write-Output ("allow`tno-match`tno deletion command")
