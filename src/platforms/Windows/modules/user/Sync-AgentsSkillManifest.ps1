<#
.SYNOPSIS
  Sync committed (bundled) skill directories into ~/.agents/skills/ as symlinks.

.DESCRIPTION
  Creates per-skill directory symlinks in ~/.agents/skills/ for each
  subdirectory under the resolved agents overlay skills/ tree. Fetched skills are
  synced separately by the post-apply step.

  A second source may be layered in through ExtraSkillsSource (used for the
  fetched superpowers plugin). A skill name defined by more than one source is
  ambiguous and fails fast.

  Directory symlinks require Developer Mode or an elevated session.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout root.

.PARAMETER User
  Username from the user registry.

.PARAMETER Enabled
  True creates symlinks, false removes managed symlinks and leaves fetched
  directories intact.

.PARAMETER ExtraSkillsSource
  Optional absolute path to an additional skills source directory.

.NOTES
  Environment variables: (none)
#>
function Sync-AgentsSkillManifest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter()]
    [string]$ExtraSkillsSource
  )

  # Committed (bundled) skills live in the agents overlay's skills/ entry.
  $skillsSource = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'agents' -EntryName 'skills' -RepoRoot $RepoRoot
  $skillsDir    = Join-Path -Path $HOME     -ChildPath ".agents\skills"

  $skillSources = @($skillsSource)
  if (-not [string]::IsNullOrWhiteSpace($ExtraSkillsSource)) {
    $skillSources += $ExtraSkillsSource
  }

  # WHY: a link is managed only when its target lies inside a declared source, so a
  # link pointing anywhere else is foreign and never touched.
  $isManagedTarget = {
    param([string]$linkTarget)
    foreach ($source in $skillSources) {
      $prefix = $source.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
      if ($linkTarget.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
    return $false
  }

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Check Developer Mode once upfront so any failure names the missing privilege.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      throw "Sync-AgentsSkillManifest requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
    }
  }

  if (-not $Enabled) {
    # Removes only per-skill symlinks pointing into a declared skill source. Real
    # directories (fetched clawhub downloads) stay intact.
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $skillsDir -Force
      foreach ($child in $children) {
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                       -and $child.LinkType -eq 'SymbolicLink'
        if ($isSymlink -and (& $isManagedTarget $child.Target)) {
          Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $child.FullName
          Remove-Item -LiteralPath $child.FullName -Force
          Write-NucleusInfo -CommandName 'skills' "removed managed skill symlink: $($child.FullName)"
        }
      }
    }
    return
  }

  # WHY: the overlay skills directory is required, but a layered extra source only
  # exists once that plugin is provisioned, so its absence means there is nothing
  # to layer: reported, never fatal.
  if (-not (Test-Path -LiteralPath $skillsSource -PathType Container)) {
    Write-NucleusError -CommandName 'skills' "Sync-AgentsSkillManifest: skills source dir not found: $skillsSource"
    return
  }
  $skillSourcesToEnumerate = @(
    $skillSources | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
  )
  foreach ($absent in @($skillSources | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })) {
    Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: optional skill source not provisioned, skipping: $absent"
  }

  if (Test-Path -LiteralPath $skillsDir) {
    $skillsDirItem = Get-Item -LiteralPath $skillsDir -Force
    $isWholeDirSymlink = ($skillsDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                           -and $skillsDirItem.LinkType -eq 'SymbolicLink'
    if ($isWholeDirSymlink) {
      Write-NucleusError -CommandName 'skills' "Sync-AgentsSkillManifest: $skillsDir is a whole-dir symlink — remove it manually and re-run apply."
      return
    }
  }

  # ~/.agents/skills\ must be a real writable directory so fetched clawhub
  # downloads land outside the tracked repo tree.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force > $null
    Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: created $skillsDir"
  }

  # Group sources by skill name so a name from two sources is rejected rather than
  # silently winning a race.
  $sourceEntriesBySkill = @{}
  foreach ($source in $skillSourcesToEnumerate) {
    $sourceEntries = Get-ChildItem -LiteralPath $source -Force -Directory
    foreach ($sourceEntry in $sourceEntries) {
      if ($sourceEntriesBySkill.ContainsKey($sourceEntry.Name)) {
        Write-NucleusError -CommandName 'skills' "Sync-AgentsSkillManifest: skill '$($sourceEntry.Name)' is provided by more than one source ('$($sourceEntriesBySkill[$sourceEntry.Name])' and '$($sourceEntry.FullName)'); keep it in one place"
        return
      }
      $sourceEntriesBySkill[$sourceEntry.Name] = $sourceEntry.FullName
    }
  }

  # Managed links whose source entry no longer exists in any declared source.
  $existingChildren = Get-ChildItem -LiteralPath $skillsDir -Force
  foreach ($child in $existingChildren) {
    $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $child.LinkType -eq 'SymbolicLink'
    if (-not $isSymlink) {
      continue
    }
    if (-not (& $isManagedTarget $child.Target)) {
      continue
    }
    if (-not (Test-Path -LiteralPath $child.Target)) {
      Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $child.FullName
      Remove-Item -LiteralPath $child.FullName -Force
      Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: removed stale skill link for $($child.Name) (source removed)"
    }
  }

  # Non-directory entries (.gitkeep etc.) are skipped; only skill directories
  # receive symlinks.
  foreach ($skillName in ($sourceEntriesBySkill.Keys | Sort-Object)) {
    $sourcePath = $sourceEntriesBySkill[$skillName]
    $linkPath = Join-Path -Path $skillsDir -ChildPath $skillName
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $sourcePath, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink: no-op.
        }
        # wrong target
        Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # A real directory here could be a fetched clawhub download of the same name, or
        # user data. Fail fast so nothing is silently overwritten.
        Write-NucleusError -CommandName 'skills' "Sync-AgentsSkillManifest: $linkPath is a real directory — if it is a fetched clawhub download for a skill that has been re-committed, remove it and re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourcePath > $null
    Set-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
    Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: linked $linkPath -> $sourcePath"
  }
}
