<#
.SYNOPSIS
  Sync the user-level ~/.agents directory as a managed per-subdir layout.

.DESCRIPTION
  Creates %USERPROFILE%\.agents\ as a real directory, then a per-entry symlink inside it
  for every top-level entry of the resolved agents overlay (src\users\<username>\agents\
  with src\users\default\ as fallback), except skills\.

  skills\ belongs to Sync-AgentsSkillManifest and may hold fetched clawhub downloads
  that must stay out of the tracked repo tree, which the real directory plus
  per-subdir symlinks allows: clawhub writes into ~/.agents\skills\ without those writes
  landing in the repo.

  Conflict handling:
    - Whole-dir symlink at ~/.agents  -> fail fast (remove manually).
    - Correct per-subdir symlink  -> no-op.
    - Wrong per-subdir symlink    -> remove and recreate.
    - Real path at sub-entry      -> fail fast (no silent overwrite).
    - Stale per-subdir symlink    -> removed (source entry deleted from repo).

  Directory symlinks need Developer Mode or an elevated session; system.dsc.yml
  (Microsoft.Windows.Settings/DeveloperMode) enables Developer Mode here. Symlinks beat
  NTFS junctions because editors and language servers follow the link target rather than
  NTFS reparse data.

.PARAMETER Enabled
  Mandatory: true ensures the managed symlinks exist, false removes them, leaving
  unrecognised symlinks and real directories untouched.

.EXAMPLE
  Sync-AgentsConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>
function Sync-AgentsConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $agentsDir    = Join-Path -Path $HOME     -ChildPath ".agents"

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Directory symlinks need Developer Mode or an elevated session. Check once
  # upfront so the failure message is actionable.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      throw "Sync-AgentsConfig requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove per-subdir symlinks pointing into the managed source,
    # leaving unrecognised symlinks and real directories untouched.
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $agentsDir -Force
      foreach ($child in $children) {
        if ($child.Name -eq "skills") { continue }  # managed by Sync-AgentsSkillManifest
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                       -and $child.LinkType -eq 'SymbolicLink'
        if ($isSymlink) {
          $expectedSource = $null
          # check-suppress:suppression_doc: overlay entry may have been removed; cleanup is best-effort.
          try {
            $expectedSource = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'agents' -EntryName $child.Name -RepoRoot $RepoRoot
          } catch {
            $expectedSource = $null
          }
          if ($null -ne $expectedSource -and [string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "agents-config" -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Force
            Write-NucleusInfo -CommandName 'agents-config' "removed managed agents subdir symlink: $($child.FullName)"
          }
        }
      }
    }
    return
  }

  $entryNames = Get-UserConfigFirstLevelEntryList -User $User -ConfigName 'agents' -RepoRoot $RepoRoot
  if ($entryNames.Count -eq 0) {
    Write-NucleusError -CommandName 'agents-config' "Sync-AgentsConfig: no agents overlay entries found for user '$User'"
    return
  }

  if (Test-Path -LiteralPath $agentsDir) {
    $agentsDirItem = Get-Item -LiteralPath $agentsDir -Force
    $isWholeDirSymlink = ($agentsDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                           -and $agentsDirItem.LinkType -eq 'SymbolicLink'
    if ($isWholeDirSymlink) {
      Write-NucleusError -CommandName 'agents-config' "Sync-AgentsConfig: $agentsDir is a whole-dir symlink — remove it manually and re-run apply so per-subdir symlinks can be created."
      return
    }
  }

  # Ensure ~/.agents\ exists as a real (writable) directory.
  if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $agentsDir > $null
    Write-NucleusInfo -CommandName 'agents-config' "Sync-AgentsConfig: created $agentsDir"
  }

  # Remove stale per-subdir symlinks whose overlay entry is gone.
  $existingChildren = Get-ChildItem -LiteralPath $agentsDir -Force
  foreach ($child in $existingChildren) {
    if ($child.Name -eq "skills") { continue }  # managed by Sync-AgentsSkillManifest
    $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $child.LinkType -eq 'SymbolicLink'
    if ($isSymlink) {
      $expectedSource = $null
      # check-suppress:suppression_doc: overlay entry may have been removed; stale symlink cleanup is best-effort.
      try {
        $expectedSource = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'agents' -EntryName $child.Name -RepoRoot $RepoRoot
      } catch {
        $expectedSource = $null
      }
      if ($null -ne $expectedSource -and [string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $expectedSource)) {
          Remove-ManagedSymlinkDeleteProtection -Context "agents-config" -Path $child.FullName
          Remove-Item -LiteralPath $child.FullName -Force
          Write-NucleusInfo -CommandName 'agents-config' "Sync-AgentsConfig: removed stale link for $($child.Name) (source removed)"
        }
      }
    }
  }

  # Create or update per-entry symlinks for every first-level entry except skills\
  # (managed independently by Sync-AgentsSkillManifest).
  foreach ($entryName in $entryNames) {
    if ($entryName -eq "skills") { continue }  # owned by Sync-AgentsSkillManifest
    $entryPath = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'agents' -EntryName $entryName -RepoRoot $RepoRoot
    $linkPath = Join-Path -Path $agentsDir -ChildPath $entryName
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $entryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }
        # Wrong target (leftover from a previous checkout path): replace.
        Remove-ManagedSymlinkDeleteProtection -Context "agents-config" -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # Real file or directory: fail fast to prevent silent data loss.
        Write-NucleusError -CommandName 'agents-config' "Sync-AgentsConfig: $linkPath is not a managed symlink — merge any wanted content into $entryPath and remove it, then re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $entryPath > $null
    Set-ManagedSymlinkDeleteProtection -Context "agents-config" -Path $linkPath
    Write-NucleusInfo -CommandName 'agents-config' "Sync-AgentsConfig: linked $linkPath -> $entryPath"
  }
}
