<#
.SYNOPSIS
  Sync committed (bundled) skill directories into ~/.agents/skills/ as symlinks.

.DESCRIPTION
  Creates per-skill directory symlinks in ~/.agents/skills/ for each
  subdirectory under src/modules/configs/agents/skills/. Bundled skills
  (MIT-0/MIT/Apache) are committed to the repo; fetched skills are synced
  separately by the post-apply step.

  Directory symlinks require Developer Mode or an elevated session.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout root.

.PARAMETER Enabled
  True ensures symlinks exist; false removes managed symlinks (leaves
  fetched directories intact).

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>
function Sync-AgentsSkill {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # Committed (bundled) skills live under this path in the repo.
  $skillsSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents\skills"
  $skillsDir    = Join-Path -Path $HOME     -ChildPath ".agents\skills"

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      Write-Error "Sync-AgentsSkills requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
      return
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove only per-skill symlinks that point into the committed
    # source.  Real directories (fetched / clawhub downloads) are left intact.
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $skillsDir -Force
      foreach ($child in $children) {
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                       -and $child.LinkType -eq 'SymbolicLink'
        if ($isSymlink) {
          $expectedSource = Join-Path -Path $skillsSource -ChildPath $child.Name
          if ([string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Force
            Write-Output "skills: removed managed skill symlink: $($child.FullName)"
          }
        }
      }
    }
    return
  }

  if (-not (Test-Path -LiteralPath $skillsSource -PathType Container)) {
    Write-Error "skills: Sync-AgentsSkills: skills source dir not found: $skillsSource"
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
      Write-Output "skills: Sync-AgentsSkills: migrated ~/.agents\skills from symlink to real directory"
    }
  }

    # Ensure ~/.agents\skills\ exists as a real (writable) directory so fetched
  # clawhub downloads can land here without entering the tracked repo tree.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force > $null
    Write-Output "skills: Sync-AgentsSkills: created $skillsDir"
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
          Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $child.FullName
          Remove-Item -LiteralPath $child.FullName -Force
          Write-Output "skills: Sync-AgentsSkills: removed stale skill link for $($child.Name) (source removed)"
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
        Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # Real directory in place of a committed skill — could be a fetched
        # (clawhub) download with the same name, or user data.  Fail fast to
        # prevent silent overwrites; the operator must resolve the conflict.
        Write-Error "skills: Sync-AgentsSkills: $linkPath is a real directory — if it is a fetched clawhub download for a skill that has been re-committed, remove it and re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $skillEntry.FullName > $null
    Set-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
    Write-Output "skills: Sync-AgentsSkills: linked $linkPath -> $($skillEntry.FullName)"
  }
}
