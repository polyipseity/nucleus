<#
.SYNOPSIS
  Sync committed (System 1) skill directories into ~/.agents/skills/ as symlinks.

.DESCRIPTION
  Creates %USERPROFILE%\.agents\skills\ as a real (writable) directory, then
  creates a per-skill directory symbolic link inside it for every subdirectory
  committed to src\modules\configs\agents\skills\ (System 1 / AGPL-compatible
  skills).

  System 1 skills are committed to the repository because their license is
  AGPL-compatible (MIT-0, MIT, Apache 2.0, etc.).  System 2 skills are managed
  by the post-apply sync step in apply.ps1 (Sync-AgentsSkills is NOT called for
  System 2); clawhub downloads them directly into %USERPROFILE%\.agents\skills\
  at apply time without committing any files to the repo.

  Non-directory entries in src\modules\configs\agents\skills\ (such as .gitkeep)
  are skipped — only skill subdirectories receive symlinks.

  Migration safety:
    - Old whole-dir symlink to skills source -> removed; real directory created.
    - Correct per-skill symlink  -> no-op.
    - Wrong per-skill symlink    -> remove and recreate.
    - Real directory at skill path -> fail fast (could be System 2 download or
      user data; operator must resolve the conflict manually).
    - Stale per-skill symlink (source removed) -> removed automatically.

  Directory symbolic links require Developer Mode or an elevated session.
  Developer Mode is enabled on this machine via system.dsc.yml
  (Microsoft.Windows.Settings/DeveloperMode).

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  When $true (default), ensures per-skill symlinks exist for all committed
  skills.  When $false, removes managed per-skill symlinks (those pointing into
  the committed source); real directories from System 2 clawhub downloads are
  left untouched.

.OUTPUTS
  None.  Writes status messages to the host.

.EXAMPLE
  Sync-AgentsSkills -RepoRoot 'C:\Users\user\repos\nucleus'

.EXAMPLE
  # Remove only managed per-skill symlinks (cleanup path); leave System 2 dirs:
  Sync-AgentsSkills -RepoRoot 'C:\Users\user\repos\nucleus' -Enabled:$false
#>
function Sync-AgentsSkills {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [bool]$Enabled = $true
  )

  # Committed (System 1) skills live under this path in the repo.
  $skillsSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents\skills"
  $skillsDir    = Join-Path -Path $HOME     -ChildPath ".agents\skills"

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      Write-Error "Sync-AgentsSkills requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
      return
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove only per-skill symlinks that point into the committed
    # source.  Real directories (System 2 / clawhub downloads) are left intact.
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $skillsDir -Force
      foreach ($child in $children) {
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                       -and $child.LinkType -eq 'SymbolicLink'
        if ($isSymlink) {
          $expectedSource = Join-Path -Path $skillsSource -ChildPath $child.Name
          if ([string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $child.FullName -Force
            Write-Host "nucleus: removed managed skill symlink: $($child.FullName)"
          }
        }
      }
    }
    return
  }

  if (-not (Test-Path -LiteralPath $skillsSource -PathType Container)) {
    Write-Error "nucleus: Sync-AgentsSkills: skills source dir not found: $skillsSource"
    return
  }

  # Migration: if ~/.agents\skills\ is the old whole-dir symlink pointing at
  # $skillsSource, remove it so a real directory can be created in its place.
  if (Test-Path -LiteralPath $skillsDir) {
    $skillsDirItem = Get-Item -LiteralPath $skillsDir -Force
    $isWholeDirSymlink = ($skillsDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                           -and $skillsDirItem.LinkType -eq 'SymbolicLink'
    if ($isWholeDirSymlink) {
      Remove-Item -LiteralPath $skillsDir -Force
      Write-Host "nucleus: Sync-AgentsSkills: migrated ~/.agents\skills from symlink to real directory"
    }
  }

  # Ensure ~/.agents\skills\ exists as a real (writable) directory so System 2
  # clawhub downloads can land here without entering the tracked repo tree.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
    Write-Host "nucleus: Sync-AgentsSkills: created $skillsDir"
  }

  # Remove stale per-skill symlinks: committed skills that have since been
  # removed from src\modules\configs\agents\skills\.
  $existingChildren = Get-ChildItem -LiteralPath $skillsDir -Force
  foreach ($child in $existingChildren) {
    $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $child.LinkType -eq 'SymbolicLink'
    if ($isSymlink) {
      $expectedSource = Join-Path -Path $skillsSource -ChildPath $child.Name
      if ([string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Managed per-skill symlink: remove if its source no longer exists.
        if (-not (Test-Path -LiteralPath $expectedSource)) {
          Remove-Item -LiteralPath $child.FullName -Force
          Write-Host "nucleus: Sync-AgentsSkills: removed stale skill link for $($child.Name) (source removed)"
        }
      }
    }
  }

  # Create or update per-skill symlinks for every subdirectory committed to
  # src\modules\configs\agents\skills\.  Non-directory entries (.gitkeep etc.)
  # are skipped; only skill directories receive symlinks.
  $sourceEntries = Get-ChildItem -LiteralPath $skillsSource -Force -Directory
  foreach ($skillEntry in $sourceEntries) {
    $linkPath = Join-Path -Path $skillsDir -ChildPath $skillEntry.Name
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $skillEntry.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }
        # Wrong target: replace symlink.
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # Real directory in place of a committed skill — could be a System 2
        # (clawhub) download with the same name, or user data.  Fail fast to
        # prevent silent overwrites; the operator must resolve the conflict.
        Write-Error "nucleus: Sync-AgentsSkills: $linkPath is a real directory — if it is a System 2 clawhub download for a skill that has been re-committed, remove it and re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $skillEntry.FullName | Out-Null
    Write-Host "nucleus: Sync-AgentsSkills: linked $linkPath -> $($skillEntry.FullName)"
  }
}
