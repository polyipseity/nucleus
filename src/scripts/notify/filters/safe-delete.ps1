<#
.SYNOPSIS
  safe-delete filter: denies the spellings that bypass the safe-delete layer and
  applies settings.unproven to a deletion command whose redirect it cannot prove.

.DESCRIPTION
  Windows twin of filters/safe-delete.sh.

    filters\safe-delete.ps1 --settings <json> --command <text>
    stdout: decision<TAB>rule<TAB>reason

  Rule families, name for name with the three branches of safe-delete-guard, plus
  the redirect question. No hook file registers that guard any more: what remains
  is the PATH command safe-delete-guard on POSIX and the safe-delete-guard.cmd shim
  on Windows, which a caller can still name directly.

    native-path        an absolute or relative path to the delete binary
    escaped-spelling   a backslash-escaped deletion command, which skips the alias
    cmd-shell          cmd.exe, which is never allowed on any host
    unproven-redirect  a deletion command whose redirect is unproven, which is
                       treated as not redirected
    no-match           nothing to gate

  An unproven redirect is treated as not redirected: settings.unproven says what
  that gets, so deny (the registry default) blocks the command, route puts it to
  the approval sources, and allow lets it through. PowerShell has no proven
  redirect: the deletion words resolve through the alias table, which the profile
  rewrites and a hook cannot see, so every deletion word falls to
  settings.unproven.

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
# WHY -ilike rather than -like: PowerShell folds case for -like already, so this
# changes no verdict. Naming the operator says so, where -like invites a reader to
# assume the family is case-sensitive and add a -clike that would reopen the bypass.
if ($Command -ilike '*/bin/rm*' -or $Command -ilike './*rm*') {
  Write-Output ("deny`tnative-path`tnative rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.")
  exit 0
}
$escaped = @('\rm', '\del', '\rd', '\erase', '\ri', '\unlink', '\shred')
foreach ($spelling in $escaped) {
  # WHY IndexOf with OrdinalIgnoreCase: String.Contains is ordinal, so an uppercase
  # spelling such as `\RM` slipped a family whose whole job is to catch it and
  # answered no-match, which reads as allow.
  if ($Command.IndexOf($spelling, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    Write-Output ("deny`tescaped-spelling`ta backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.")
    exit 0
  }
}
if ($Command -ilike '*cmd.exe*' -or $Command -ilike '* cmd *') {
  Write-Output ("deny`tcmd-shell`tcmd.exe is not allowed. Use pwsh instead.")
  exit 0
}

# A deletion command as the invoked word, optionally behind sudo. The pattern
# anchors on a command separator, so the same verb in an argument position or
# inside quotes does not match.
# WHY -imatch: PowerShell folds case for these words, so DEL, Del, and del are one
# deletion; a case-sensitive test would let an uppercase spelling fall through to
# no-match, which reads as allow. Every family above folds case for that same
# reason; the setting compared below does not.
$deletion = '(^|[;&|(]|&&|\|\|)\s*(sudo\s+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)(\s|$)'
if ($Command -imatch $deletion) {
  $verb = $Matches[3]

  # WHY no proven redirect on Windows: the six shim names are exactly the words
  # PowerShell resolves through its alias table, and the profile replaces that
  # table (Set-Alias rm Invoke-SafeDelete in src/scripts/shell/profile.ps1). A
  # session without the profile runs the word on the real delete path, while the
  # rip.exe shims serve the non-PowerShell contexts (cmd.exe, Git Bash, scripts),
  # so alias precedence rather than PATH decides what the word means and no PATH
  # comparison can prove the redirect. Every deletion word falls to
  # settings.unproven.
  if (-not [string]::IsNullOrEmpty($Matches[2])) {
    # WHY nothing is proven behind sudo: sudo runs the word in an environment this
    # repository does not manage (the tree carries no sudoers PATH policy).
    $why = "$verb runs behind sudo, whose PATH this repository does not manage"
  }
  else {
    $why = "$verb has no provable redirect in PowerShell: the deletion shims serve the non-PowerShell contexts, and the profile aliases that redirect the word are invisible to this filter"
  }

  # WHY the knob is named: settings.unproven is per-filter rather than per-verb, so
  # a verb that can never be proven (Remove-Item) needs a discoverable escape.
  # WHY -ceq: the POSIX twin matches the setting with a case-sensitive case, so a
  # value spelled 'Allow' must not enable the redirect exemption on one host only.
  if ($unproven -ceq 'deny') {
    Write-Output ("deny`tunproven-redirect`tdeletion command: $why, so it is treated as not redirected. Use rip instead (rip -u to undo), or set harness-filters.json safe-delete.settings.unproven to route or allow.")
    exit 0
  }
  if ($unproven -ceq 'route') {
    Write-Output ("ask`tunproven-redirect`tdeletion command: $why, so it is treated as not redirected and the harness prompts")
    exit 0
  }
  if ($unproven -ceq 'allow') {
    Write-Output ("allow`tunproven-redirect`tdeletion command: $why, and settings.unproven allows an unproven redirect")
    exit 0
  }
  Write-Output ("deny`tunproven-redirect`tdeletion command: $why, and settings.unproven is '$unproven' rather than deny, route, or allow, so the unproven redirect is denied. Use rip instead (rip -u to undo).")
  exit 0
}

Write-Output ("allow`tno-match`tno deletion command")
