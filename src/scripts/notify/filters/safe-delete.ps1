<#
.SYNOPSIS
  safe-delete filter: denies the spellings that bypass the safe-delete layer and
  applies settings.unproven to a deletion command whose redirect it cannot prove.

.DESCRIPTION
  Windows twin of filters/safe-delete.sh.

    filters\safe-delete.ps1 --settings <json> --command <text>
    stdout: decision<TAB>rule<TAB>reason

  Rule families, name for name with the three branches of the retired guard, plus
  the redirect question:

    native-path        an absolute or relative path to the delete binary
    escaped-spelling   a backslash-escaped deletion command, which skips the alias
    cmd-shell          cmd.exe, which is never allowed on any host
    proven-redirect    a deletion command whose word resolves to the managed shim
    unproven-redirect  a deletion command whose redirect is unproven, which is
                       treated as not redirected
    no-match           nothing to gate

  An unproven redirect is treated as not redirected: settings.unproven says what
  that gets, so deny (the registry default) blocks the command, route puts it to
  the approval sources, and allow lets it through. A redirect is proven only when
  the deletion word resolves to the shim Sync-SafeDelete.ps1 deploys, so a PATH
  that reaches a plain binary and a shim that is absent both read as unproven.

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

# A deletion command as the invoked word, optionally behind sudo. The pattern
# anchors on a command separator, so the same verb in an argument position or
# inside quotes does not match.
$deletion = '(^|[;&|(]|&&|\|\|)\s*(sudo\s+)?(rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item)(\s|$)'
if ($Command -cmatch $deletion) {
  $verb = $Matches[3]

  # The managed shim for this verb: Sync-SafeDelete.ps1 copies rip.exe into
  # %USERPROFILE%\.local\bin as rm.exe and the rest of the deletion union, so that
  # copy is what PATH reaches.
  $wrapper = $null
  if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
    $wrapper = Join-Path -Path (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin') -ChildPath "$verb.exe"
  }

  # WHY -CommandType Application: a PATH lookup only, the visibility the POSIX twin
  # gets from `sh -c 'command -v'`, so the built-in rm alias and a profile function
  # are not mistaken for a redirect.
  # check-suppress:suppression_doc: the verb may resolve to nothing, which is the unproven case and is reported as such
  $resolvedCommand = Get-Command -Name $verb -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  $resolved = $null
  if ($null -ne $resolvedCommand) { $resolved = [string]$resolvedCommand.Source }

  if ($null -ne $wrapper -and -not [string]::IsNullOrEmpty($resolved)) {
    # WHY OrdinalIgnoreCase: Windows resolves and reports a path case-insensitively.
    $resolvedFull = [System.IO.Path]::GetFullPath($resolved)
    $wrapperFull = [System.IO.Path]::GetFullPath($wrapper)
    if ([string]::Equals($resolvedFull, $wrapperFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Output ("allow`tproven-redirect`tdeletion command: $verb resolves to the managed safe-delete shim at $resolved")
      exit 0
    }
  }

  if ($null -eq $wrapper) {
    $why = "$verb has no managed shim to compare against because USERPROFILE is unset"
  }
  elseif ([string]::IsNullOrEmpty($resolved)) {
    $why = "$verb does not resolve on PATH"
  }
  else {
    $why = "$verb resolves to $resolved, not the managed safe-delete shim at $wrapper"
  }

  # WHY -ceq: the POSIX twin matches the setting with a case-sensitive case, so a
  # value spelled 'Allow' must not enable the redirect exemption on one host only.
  if ($unproven -ceq 'deny') {
    Write-Output ("deny`tunproven-redirect`tdeletion command: $why, so it is treated as not redirected. Use rip instead (rip -u to undo).")
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
