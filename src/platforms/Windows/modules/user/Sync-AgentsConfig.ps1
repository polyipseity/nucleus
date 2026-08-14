<#
.SYNOPSIS
  Sync the user-level ~/.agents directory as a managed per-subdir layout.

.DESCRIPTION
  Creates %USERPROFILE%\.agents\ as a real directory, then creates a per-entry
  directory symbolic link inside it for every top-level entry in
  src\modules\configs\agents\ except skills\.

  skills\ is excluded here because it is managed by Sync-AgentsSkillManifest and may
  contain fetched (clawhub) skill downloads that must not be committed.  Using
  a real ~/.agents\ directory with per-subdir symlinks (rather than a single
  whole-dir symlink) lets clawhub write into ~/.agents\skills\ without those
  writes landing inside the tracked repo tree.

  Conflict handling:
    - Whole-dir symlink at ~/.agents  -> fail fast (remove manually).
    - Correct per-subdir symlink  -> no-op.
    - Wrong per-subdir symlink    -> remove and recreate.
    - Real path at sub-entry      -> fail fast (no silent overwrite).
    - Stale per-subdir symlink    -> removed (source entry deleted from repo).

  Directory symbolic links require Developer Mode or an elevated session.
  Developer Mode is enabled on this machine via system.dsc.yml
  (Microsoft.Windows.Settings/DeveloperMode), which permits unprivileged symlink
  creation.  Symlinks are preferred over NTFS junctions because they are a proper
  POSIX-equivalent reparse point and are followed correctly by cross-host tooling
  (editors, language servers) that inspects the link target rather than traversal
  through reparse data.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  Whether per-subdir symlinks should be managed. Mandatory: caller must
  explicitly choose true (ensure symlinks exist) or false (remove managed
  symlinks). When $false, unrecognised symlinks and real directories are
  left untouched.

.EXAMPLE
  Sync-AgentsConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true

.EXAMPLE
  # Remove all managed per-subdir symlinks (cleanup path):
  Sync-AgentsConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$false

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

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      Write-NucleusError -CommandName 'agents-config' "Sync-AgentsConfig requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
      return
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove per-subdir symlinks that point into the managed source.
    # Leave unrecognised symlinks and real directories untouched.
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

  # Remove stale per-subdir symlinks whose resolved overlay entry no longer exists.
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

  # Create or update per-entry symlinks for every merged first-level entry except
  # skills\ (managed independently by Sync-AgentsSkillManifest).
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
        # Wrong target (e.g. leftover from a previous checkout path): replace.
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
