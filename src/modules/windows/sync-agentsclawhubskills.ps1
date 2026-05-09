<#
.SYNOPSIS
  Download and update fetched (non-AGPL-compatible) skills via the clawhub CLI.

.DESCRIPTION
  Reads the declarative fetched skill manifest at
  src\modules\configs\agents\clawhub-skills.json and converges
  %USERPROFILE%\.agents\skills\ with its contents.

  Fetched skills are those whose license is not AGPL-compatible and therefore
  cannot be committed to this repository.  Bundled (AGPL-compatible, committed)
  skills are managed by Sync-AgentsSkills; this function manages only fetched
  clawhub-downloaded skills.

  For each slug in the manifest:
    -   If a committed-skill symlink (bundled) already occupies that slot, a
      warning is printed and the slug is skipped; the conflict must be resolved
      manually before clawhub can write there.
    - Otherwise, `clawhub install --workdir $HOME\.agents --no-input <slug>` is
      run.  A failure is non-fatal: the system configuration already applied
      successfully; skill sync is additive.

  Stale cleanup removes real directories in %USERPROFILE%\.agents\skills\ that
  carry a .clawhub\origin.json marker (written by clawhub at install time) but
  whose slug is no longer present in the manifest.  Directories without that
  marker (symlinks, user content) are never touched.

  When $Enabled is $false the function is a no-op; existing clawhub downloads are
  left intact because they are not managed symlinks and removing them would exceed
  the managed-scope boundary.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  When $true (default), converges fetched skill directories with the manifest.
  When $false, skips the sync entirely; already-downloaded skill directories are
  left intact.

.OUTPUTS
  None.  Writes status messages to the host.

.EXAMPLE
  Sync-AgentsClawhubSkills -RepoRoot 'C:\Users\user\repos\nucleus'

.EXAMPLE
  # Skip the fetched skill sync without removing any existing downloads:
  Sync-AgentsClawhubSkills -RepoRoot 'C:\Users\user\repos\nucleus' -Enabled:$false
#>
function Sync-AgentsClawhubSkills {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [bool]$Enabled = $true
  )

  if (-not $Enabled) {
    # When disabled, leave any existing fetched clawhub downloads untouched.
    # Unlike Sync-AgentsSkills there are no managed symlinks to clean up here;
    # the downloaded directories are self-contained real directories created by
    # clawhub.
    Write-Host "nucleus: Sync-AgentsClawhubSkills: disabled; skipping fetched skill sync"
    return
  }

  # Read the declarative fetched skill manifest.
  $manifest = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents\clawhub-skills.json"
  if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host "nucleus: Sync-AgentsClawhubSkills: manifest not found at $manifest; skipping"
    return
  }

  $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
  # ConvertFrom-Json returns $null for a missing key; coerce to an empty array so
  # subsequent Count and -contains checks work uniformly.
  $slugs = if ($null -ne $data.skills) { @($data.skills) } else { @() }

  if ($slugs.Count -eq 0) {
    Write-Host "nucleus: Sync-AgentsClawhubSkills: no fetched skills in manifest; skipping"
    return
  }

  $skillsDir = Join-Path -Path $HOME -ChildPath ".agents\skills"

  # Ensure ~/.agents\skills\ exists as a real directory.  Sync-AgentsSkills
  # creates it during apply, but this guard makes the function safe to call
  # standalone (e.g. for testing) before Sync-AgentsSkills has run.
  if (-not (Test-Path -LiteralPath $skillsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
    Write-Host "nucleus: Sync-AgentsClawhubSkills: created $skillsDir"
  }

  # Resolve the clawhub binary.  Invoke-BunSetup (called earlier in apply.ps1)
  # installs clawhub and prepends ~\.bun\bin to PATH for this session.
  # Provisioning clawhub is Invoke-BunSetup's responsibility; this function
  # does not attempt a fallback install — if clawhub is absent, Invoke-BunSetup
  # failed and the operator should investigate.
  $bunBinDir = Join-Path -Path $HOME -ChildPath ".bun\bin"
  $clawhubExe = Get-Command -Name "clawhub" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
  # -ErrorAction SilentlyContinue is intentional: absence of clawhub is an
  # expected probe condition when Invoke-BunSetup failed; the if-guard below
  # checks the result immediately.
  if ([string]::IsNullOrEmpty($clawhubExe)) {
    # Get-Command may miss the binary if the PATH update from Invoke-BunSetup
    # did not propagate to this session; check the bun bin directory directly.
    $clawhubCandidate = Join-Path -Path $bunBinDir -ChildPath "clawhub"
    if (Test-Path -LiteralPath $clawhubCandidate) {
      $clawhubExe = $clawhubCandidate
    }
  }

  if ([string]::IsNullOrEmpty($clawhubExe)) {
    Write-Warning "nucleus: Sync-AgentsClawhubSkills: clawhub not found; Invoke-BunSetup must have failed; skipping fetched skill sync"
    return
  }

  # Install or update each skill listed in the manifest.
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
        # A committed-skill (bundled) symlink occupies this slot.  Skip rather
        # than overwriting the managed symlink; the operator must remove the slug
        # from clawhub-skills.json or the committed skill from the repo first.
        Write-Warning "nucleus: Sync-AgentsClawhubSkills: skipping '$slug' — a committed-skill symlink exists at $skillPath; remove it from clawhub-skills.json or from src\modules\configs\agents\skills\"
        continue
      }
      # Unlock an existing fetched skill directory before updating so clawhub can
      # overwrite files that were locked ReadOnly on a previous install.
      # Mirrors POSIX chmod -R u+w before update.
      Get-ChildItem -LiteralPath $skillPath -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
          if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly
          }
        }
    }

    Write-Host "nucleus: Sync-AgentsClawhubSkills: installing/updating fetched skill '$slug'..."
    # Non-zero exit from clawhub is non-fatal: the system apply succeeded; skill
    # sync is additive.  A warning is printed and the loop continues.
    & $clawhubExe install --workdir "$HOME\.agents" --no-input $slug
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "nucleus: Sync-AgentsClawhubSkills: clawhub install failed for '$slug' (system apply succeeded)"
    } elseif (Test-Path -LiteralPath $skillPath -PathType Container) {
      # Lock installed skill files to prevent modification outside a managed apply
      # run.  Mirrors POSIX chmod -R a-w after install.  The unlock above
      # re-opens write access before the next update.
      Get-ChildItem -LiteralPath $skillPath -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::ReadOnly }
    }
  }

  # Stale cleanup: remove real directories in ~/.agents\skills\ that carry a
  # .clawhub\origin.json marker (written by clawhub at install time, reliably
      # identifying them as fetched downloads) but whose slug is no longer in the
  # manifest.  Directories without the marker are never removed.
  if (Test-Path -LiteralPath $skillsDir -PathType Container) {
    $children = Get-ChildItem -LiteralPath $skillsDir -Force -Directory
    foreach ($child in $children) {
      $originMarker = Join-Path -Path $child.FullName -ChildPath ".clawhub\origin.json"
      if (-not (Test-Path -LiteralPath $originMarker)) {
        continue  # Not a clawhub download; skip (could be user data or bundled symlink).
      }
      if ($slugs -notcontains $child.Name) {
        Write-Host "nucleus: Sync-AgentsClawhubSkills: removing stale fetched skill '$($child.Name)' (removed from manifest)"
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
      }
    }
  }

  Write-Host "nucleus: Sync-AgentsClawhubSkills: fetched skill sync complete"
}
