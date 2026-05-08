<#
.SYNOPSIS
  Sync the user-level ~/.agents directory as a managed directory symlink.

.DESCRIPTION
  Creates %USERPROFILE%\.agents as a directory symbolic link pointing to the
  live src\modules\configs\agents\ tree in the repo checkout.  Every file
  written by a coding agent under %USERPROFILE%\.agents\ therefore appears
  immediately as an unstaged git diff, keeping user-level agent instructions
  under version control.

  Directory symbolic links (not NTFS junctions) are used because Developer Mode
  is enabled on this machine (Microsoft.Windows.Settings/DeveloperMode in
  system.dsc.yml), which permits unprivileged symlink creation.  Symlinks are
  preferred over junctions because they are a proper POSIX-equivalent reparse
  point and are correctly followed by cross-host tooling (editors, language
  servers) that inspect the link target rather than traversing the reparse data.

  Migration safety:
    - Correct symlink  -> no-op.
    - Wrong symlink    -> remove and recreate pointing to the current repo.
    - Real directory   -> fail fast with an actionable error (no silent merge).
      The operator must manually merge any wanted content into
      src\modules\configs\agents\ and remove the directory before re-running.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  When $true (default), ensures the symlink exists and points to the managed
  source.  When $false, removes the symlink if it currently points to the
  managed source (cleanup path); does nothing otherwise.

.EXAMPLE
  Sync-AgentsConfig -RepoRoot 'C:\Users\user\repos\nucleus'

.EXAMPLE
  # Remove the managed symlink (cleanup path):
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
  # Coding agents write through the symlink directly into the repo checkout so
  # every change appears as an unstaged git diff.
  $agentsSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents"
  $agentsLink   = Join-Path -Path $HOME     -ChildPath ".agents"

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      Write-Error "Sync-AgentsConfig requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
      return
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove only the symlink that points to our managed source.
    # Leave unrecognised symlinks and real directories untouched.
    if (Test-Path -LiteralPath $agentsLink) {
      $item = Get-Item -LiteralPath $agentsLink
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $item.LinkType -eq 'SymbolicLink'
      if ($isSymlink -and [string]::Equals($item.Target, $agentsSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $agentsLink -Force
        Write-Host "nucleus: removed agents config symlink: $agentsLink"
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
    $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $item.LinkType -eq 'SymbolicLink'

    if ($isSymlink) {
      if ([string]::Equals($item.Target, $agentsSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        return  # Correct symlink — no-op.
      }
      # Wrong target (e.g. leftover from a previous checkout path): replace.
      Remove-Item -LiteralPath $agentsLink -Force
    } else {
      # Real directory (or an old NTFS junction): fail fast to prevent silent
      # data loss.  The operator must manually merge any wanted content into
      # src\modules\configs\agents\ and remove the path before re-running apply.
      Write-Error "nucleus: Sync-AgentsConfig: $agentsLink is not a managed symlink — merge its content into src\modules\configs\agents\ and remove it, then re-run apply."
      return
    }
  }

  New-Item -ItemType SymbolicLink -Path $agentsLink -Target $agentsSource | Out-Null
  Write-Host "nucleus: linked agents config: $agentsLink -> $agentsSource"
}
