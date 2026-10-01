<#
.SYNOPSIS
  Download and update fetched (non-AGPL-compatible) skills via the ClawHub CLI.

.DESCRIPTION
  Reads the declarative fetched skill manifest from the per-user agents overlay
  (src\users\<username>\agents\clawhub-skills.json with src\users\default\ as
  fallback) and converges %USERPROFILE%\.agents\skills\ with its contents.

  Fetched skills are those whose license is not AGPL-compatible and therefore
  cannot be committed to this repository. Bundled skills are managed by
  Sync-AgentsSkillManifest; this function manages only fetched ClawHub skills.

  A slug whose slot is already a committed-skill symlink is skipped with a
  warning. Otherwise `clawhub install --workdir $HOME\.agents --no-input <slug>`
  runs, and a failure throws so the skill is not silently skipped.

  Stale cleanup removes real directories in %USERPROFILE%\.agents\skills\ that
  carry a .clawhub\origin.json marker (written by ClawHub at install time) but
  whose slug is no longer present in the manifest.  Directories without that
  marker (symlinks, user content) are never touched.

  When $Enabled is $false the function is a no-op; existing ClawHub downloads are
  left intact because they are not managed symlinks and removing them would exceed
  the managed-scope boundary.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER User
  Username from the user registry; the manifest resolves through the per-user
  agents overlay.

.PARAMETER Enabled
  Whether fetched skills should be synced. Mandatory: caller must explicitly
  choose true (converge with manifest) or false (skip sync). When $false,
  already-downloaded skill directories are left intact.

.OUTPUTS
  None.  Writes status messages to the host.

.EXAMPLE
  Sync-AgentsClawHubSkillManifest -RepoRoot 'C:\Users\guest\repos\nucleus' -User 'guest' -Enabled:$true
#>
function Sync-AgentsClawHubSkillManifest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [string]$User,
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  if (-not $Enabled) {
    # There are no managed symlinks to clean up here, so existing downloads
    # stay; they are self-contained directories created by clawhub.
    Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: disabled; skipping fetched skill sync"
    return
  }

  # The resolver fails fast when neither the per-user nor the default manifest
  # exists, so a missing manifest cannot pass as an empty sync.
  $manifest = Resolve-UserConfigFile -User $User -ConfigName 'agents' -RelativePath 'clawhub-skills.json' -RepoRoot $RepoRoot

  $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
  # ConvertFrom-Json returns $null for a missing key; coerce to an empty array so
  # subsequent Count and -contains checks work uniformly.
  $slugs = if ($null -ne $data.skills) { @($data.skills) } else { @() }

  if ($slugs.Count -eq 0) {
    Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: no fetched skills in manifest; skipping"
    return
  }

  $skillsDir = Join-Path -Path $HOME -ChildPath ".agents\skills"

  # Safe to call standalone before Sync-AgentsSkillManifest has created it.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force > $null
    Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: created $skillsDir"
  }

  # Invoke-BunSetup installs ClawHub and prepends ~\.bun\bin to PATH, so a
  # missing binary means Invoke-BunSetup failed.
  $bunBinDir = Get-NucleusManagedBinDir "bun"
  # check-suppress:suppression_doc: probe -- clawhub may not be installed; $null check handles absence.
  $clawhubExe = Get-Command -Name "clawhub" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrEmpty($clawhubExe)) {
    # The PATH update from Invoke-BunSetup may not have reached this session.
    $clawhubCandidate = Join-Path -Path $bunBinDir -ChildPath "clawhub"
    if (Test-Path -LiteralPath $clawhubCandidate) {
      $clawhubExe = $clawhubCandidate
    }
  }

  if ([string]::IsNullOrEmpty($clawhubExe)) {
    Write-NucleusWarning -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: clawhub not found; Invoke-BunSetup must have failed; skipping fetched skill sync"
    return
  }

  #   --workdir "$HOME\.agents"  installs to $HOME\.agents\skills\<slug>\
  #                              (default --dir value is "skills")
  #   --no-input                 disables interactive prompts for apply safety
  foreach ($slug in $slugs) {
    $skillPath = Join-Path -Path $skillsDir -ChildPath $slug
    if (Test-Path -LiteralPath $skillPath) {
      $item = Get-Item -LiteralPath $skillPath -Force
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $item.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        # A committed-skill symlink occupies this slot. The operator must drop
        # the slug from clawhub-skills.json or the committed skill from the
        # agents overlay first.
        Write-NucleusWarning -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: skipping '$slug' — a committed-skill symlink exists at $skillPath; remove it from clawhub-skills.json or from the agents overlay skills tree"
        continue
      }
      # Unlock before updating so ClawHub can overwrite files a previous
      # install locked ReadOnly.
      # check-suppress:suppression_doc: probe -- path may not exist or have no child items; pipeline handles empty.
      Get-ChildItem -LiteralPath $skillPath -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
          if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly
          }
        }
    }

    Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: installing/updating fetched skill '$slug'..."
    # Non-zero exit from clawhub is a required convergence failure: abort the
    # activation so the missing skill is not silently skipped.
    & $clawhubExe install --workdir "$HOME\.agents" --no-input $slug
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: clawhub install failed for '$slug' (exit $LASTEXITCODE)"
      throw
    } elseif (Test-Path -LiteralPath $skillPath -PathType Container) {
      # Lock the installed files, mirroring POSIX chmod -R a-w after install.
      # check-suppress:suppression_doc: probe -- path may not exist or have no child items; pipeline handles empty.
      Get-ChildItem -LiteralPath $skillPath -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::ReadOnly }
    }
  }

  # Remove directories that clawhub marked with .clawhub\origin.json but that
  # are no longer in the manifest. Anything without the marker stays.
  if (Test-Path -LiteralPath $skillsDir -PathType Container) {
    $children = Get-ChildItem -LiteralPath $skillsDir -Force -Directory
    foreach ($child in $children) {
      $originMarker = Join-Path -Path $child.FullName -ChildPath ".clawhub\origin.json"
      if (-not (Test-Path -LiteralPath $originMarker)) {
        continue  # Not a clawhub download; skip (could be user data or bundled symlink).
      }
      if ($slugs -notcontains $child.Name) {
        Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: removing stale fetched skill '$($child.Name)' (removed from manifest)"
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
      }
    }
  }

  Write-NucleusInfo -CommandName 'clawhub-skills' "Sync-AgentsClawHubSkillManifest: fetched skill sync complete"
}
