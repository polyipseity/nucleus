<#
.SYNOPSIS
  Sync the user-level ~/.agents directory as a managed NTFS junction.

.DESCRIPTION
  Creates %USERPROFILE%\.agents as an NTFS junction pointing to the live
  src\modules\configs\agents\ tree in the repo checkout.  Every file written
  by a coding agent under %USERPROFILE%\.agents\ therefore appears immediately
  as an unstaged git diff, keeping user-level agent instructions under version
  control.

  Junctions are preferred over symbolic links because they do not require
  Developer Mode or elevated privileges on modern Windows installations.

  Migration safety:
    - Correct junction  -> no-op.
    - Wrong junction    -> remove and recreate pointing to the current repo.
    - Real directory    -> fail fast with an actionable error (no silent merge).
      The operator must manually merge any wanted content into
      src\modules\configs\agents\ and remove the directory before re-running.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  When $true (default), ensures the junction exists and points to the managed
  source.  When $false, removes the junction if it currently points to the
  managed source (cleanup path); does nothing otherwise.

.EXAMPLE
  Sync-AgentsConfig -RepoRoot 'C:\Users\user\repos\nucleus'

.EXAMPLE
  # Remove the managed junction (cleanup path):
  Sync-AgentsConfig -RepoRoot 'C:\Users\user\repos\nucleus' -Enabled:$false
#>
function Sync-AgentsConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [bool]$Enabled = $true
  )

  # The managed source is always the live agents config tree in the repo.
  # Coding agents write through the junction directly into the repo checkout so
  # every change appears as an unstaged git diff.
  $agentsSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents"
  $agentsLink   = Join-Path -Path $HOME     -ChildPath ".agents"

  if (-not $Enabled) {
    # Cleanup path: remove only the junction that points to our managed source.
    # Leave unrecognised junctions and real directories untouched.
    if (Test-Path -LiteralPath $agentsLink) {
      $item = Get-Item -LiteralPath $agentsLink
      $isJunction = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $item.LinkType -eq 'Junction'
      if ($isJunction -and [string]::Equals($item.Target, $agentsSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $agentsLink -Force
        Write-Host "nucleus: removed agents config junction: $agentsLink"
      }
    }
    return
  }

  if (-not (Test-Path -LiteralPath $agentsSource -PathType Container)) {
    Write-Error "nucleus: Sync-AgentsConfig: agents config dir not found: $agentsSource"
    return
  }

  if (Test-Path -LiteralPath $agentsLink) {
    $item = Get-Item -LiteralPath $agentsLink
    $isJunction = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $item.LinkType -eq 'Junction'

    if ($isJunction) {
      if ([string]::Equals($item.Target, $agentsSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        return  # Correct junction — no-op.
      }
      # Wrong target (e.g. leftover from a previous checkout path): replace.
      Remove-Item -LiteralPath $agentsLink -Force
    } else {
      # Real directory: fail fast to prevent silent data loss.  The operator
      # must manually merge any wanted content into src\modules\configs\agents\
      # and remove the directory before re-running apply.
      Write-Error "nucleus: Sync-AgentsConfig: $agentsLink is a real directory — merge its content into src\modules\configs\agents\ and remove it, then re-run apply."
      return
    }
  }

  New-Item -ItemType Junction -Path $agentsLink -Target $agentsSource | Out-Null
  Write-Host "nucleus: linked agents config: $agentsLink -> $agentsSource"
}
