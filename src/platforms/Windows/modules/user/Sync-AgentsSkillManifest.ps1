<#
.SYNOPSIS
  Sync committed (bundled) skill directories into ~/.agents/skills/ as symlinks.

.DESCRIPTION
  Creates per-skill directory symlinks in ~/.agents/skills/ for each
  subdirectory under the resolved agents overlay skills/ tree. Bundled skills
  (MIT-0/MIT/Apache) are committed to the repo; fetched skills are synced
  separately by the post-apply step.

  A second source directory may be layered in through ExtraSkillsSource (used
  for the fetched superpowers plugin), so its skill directories land in the same
  ~/.agents/skills/ tree. A skill name defined by more than one source is
  ambiguous and fails fast.

  Directory symlinks require Developer Mode or an elevated session.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout root.

.PARAMETER User
  Username from the user registry; the skills source resolves through the
  per-user agents overlay (src/users/<username>/agents/ with src/users/default/
  as fallback).

.PARAMETER Enabled
  True creates symlinks; false removes managed symlinks (leaves
  fetched directories intact).

.PARAMETER ExtraSkillsSource
  Optional absolute path to an additional skills source directory. Its
  subdirectories are symlinked into ~/.agents/skills/ exactly like the overlay
  skills/ tree. The path must exist when provided.

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
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

  # A per-skill link is managed when its target lives inside one of the declared
  # sources.  Links pointing anywhere else are foreign and are never touched.
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

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
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
    # Cleanup path: remove only per-skill symlinks that point into a declared
    # skill source.  Real directories (fetched / clawhub downloads) are left
    # intact.
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

  # The overlay skills directory is required: it is the committed source of
  # truth.  A layered extra source (for example the superpowers plugin's skills
  # directory) only exists once that plugin has been provisioned, so its absence
  # means there is simply nothing to layer — reported, never fatal.
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

  # Ensure ~/.agents\skills\ exists as a real (writable) directory so fetched
  # clawhub downloads can land here without entering the tracked repo tree.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force > $null
    Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: created $skillsDir"
  }

  # Group the declared source entries by skill name so a name provided by more
  # than one source is rejected instead of silently winning a race.
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

  # Remove stale per-skill symlinks: managed links whose source entry no longer
  # exists in any declared skills source.
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

  # Create or update per-skill symlinks for every subdirectory committed to a
  # declared skills source.  Non-directory entries (.gitkeep etc.) are skipped;
  # only skill directories receive symlinks.
  foreach ($skillName in ($sourceEntriesBySkill.Keys | Sort-Object)) {
    $sourcePath = $sourceEntriesBySkill[$skillName]
    $linkPath = Join-Path -Path $skillsDir -ChildPath $skillName
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $sourcePath, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }
        # Wrong target: replace symlink.
        Remove-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # Real directory in place of a committed skill — could be a fetched
        # (clawhub) download with the same name, or user data.  Fail fast to
        # prevent silent overwrites; the operator must resolve the conflict.
        Write-NucleusError -CommandName 'skills' "Sync-AgentsSkillManifest: $linkPath is a real directory — if it is a fetched clawhub download for a skill that has been re-committed, remove it and re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourcePath > $null
    Set-ManagedSymlinkDeleteProtection -Context "skills" -Path $linkPath
    Write-NucleusInfo -CommandName 'skills' "Sync-AgentsSkillManifest: linked $linkPath -> $sourcePath"
  }
}
