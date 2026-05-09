# modules/sync-devrepos.ps1 — Provisions development repositories in ~/dev
# on Windows via PowerShell.
#
# Configuration: Per-user dev repository settings are defined in the centralized
# user registry (users.json). The apply.ps1 script reads that configuration,
# resolves symlink paths, and passes it to this module for provisioning.
#
# Behavior:
#   • symlinks are created if absent
#   • repos are cloned only if uninitialized
#   • direct submodules are individually checked and cloned if absent
#   • soft-fail on errors (write warnings, do not throw)
#   • remote URLs are verified and updated if needed

function Sync-DevRepos {
  <#
  .SYNOPSIS
    Provision development repositories in ~/dev on Windows.

  .DESCRIPTION
    Ensures that ~/dev contains repositories specified in the -Repositories
    parameter (which comes from the centralized user registry).

    Each repository object can specify either a symlink or a Git URL:
      - symlink: Path to symlink to instead of cloning
      - url: Git URL to clone from

    All operations soft-fail on error; missing repos or clone failures log
    warnings but do not halt provisioning.

  .PARAMETER Enabled
    Whether dev repos should be provisioned. Mandatory: caller must explicitly
    pass true to enable or false to disable. Apply.ps1 reads this from the user
    registry (users.json) to ensure enable status is derived from centralized
    configuration, not from implicit username checks.

  .PARAMETER Repositories
    Array of repository objects from the user registry. Each object must have:
      - name (string): Repository name (used for logging)
      - target (string): Target path (e.g., dev\myrepo)
      - symlink (string, optional): Path to symlink to
      - url (string, optional): Git URL to clone from

    If both symlink and url are present, symlink takes precedence.
    If neither is present, the repo is skipped with a warning.

  .EXAMPLE
    $repos = @(
      @{ name = 'nucleus'; target = 'dev\nucleus'; symlink = 'C:\path\to\repo' }
      @{ name = 'monorepo'; target = 'dev\monorepo'; url = 'git@github.com:user/monorepo.git' }
    )
    Sync-DevRepos -Enabled:$true -Repositories $repos

  .EXAMPLE
    Sync-DevRepos -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled,

    [Parameter()]
    [object[]]$Repositories = @()
  )

  if (-not $Enabled) {
    Write-Verbose "Sync-DevRepos: provisioning is disabled."
    return
  }

  if ($Repositories.Count -eq 0) {
    Write-Verbose "Sync-DevRepos: no repositories configured for this user."
    return
  }

  $userHome = [Environment]::GetFolderPath('UserProfile')
  $devDir = Join-Path -Path $userHome -ChildPath 'dev'

  # Ensure dev directory exists.
  if (-not (Test-Path -PathType Container -Path $devDir)) {
    try {
      New-Item -ItemType Directory -Path $devDir -Force | Out-Null
      Write-Verbose "Sync-DevRepos: created dev directory at $devDir"
    }
    catch {
      Write-Warning "Sync-DevRepos: failed to create dev directory $devDir : $_"
      return
    }
  }

  # Helper function: create a symlink for a repository.
  function New-RepositorySymlink {
    param(
      [Parameter(Mandatory = $true)]
      [string]$SymlinkTarget,

      [Parameter(Mandatory = $true)]
      [string]$SymlinkPath,

      [Parameter(Mandatory = $true)]
      [string]$RepoName
    )

    if (-not (Test-Path -Path $SymlinkPath)) {
      try {
        # On Windows, use New-Item with -ItemType SymbolicLink.
        # Requires admin or developer mode on Windows 10+.
        New-Item -ItemType SymbolicLink -Path $SymlinkPath -Target $SymlinkTarget -Force -ErrorAction Stop | Out-Null
        Write-Verbose "Sync-DevRepos: created symlink $SymlinkPath -> $SymlinkTarget"
      }
      catch {
        Write-Warning "Sync-DevRepos: failed to create symlink for $RepoName : $_"
      }
    }
  }

  # Helper function: initialize a repository, verify its remote is correct, and ensure
  # direct submodules are initialized.
  function Initialize-RepositoryWithSubmodule {
    param(
      [Parameter(Mandatory = $true)]
      [string]$RepoUrl,

      [Parameter(Mandatory = $true)]
      [string]$RepoTarget,

      [Parameter(Mandatory = $true)]
      [string]$RepoName
    )

    # Check if repo is initialized.
    $gitDir = Join-Path -Path $RepoTarget -ChildPath '.git'
    if (Test-Path -PathType Container -Path $gitDir) {
      # Repo already initialized; verify/update remote.
      try {
        $currentRemote = & git -C $RepoTarget config --get remote.origin.url 2>$null
        if ($currentRemote -ne $RepoUrl) {
          & git -C $RepoTarget remote set-url origin $RepoUrl 2>$null
          if ($LASTEXITCODE -eq 0) {
            Write-Verbose "Sync-DevRepos: updated remote for $RepoName to $RepoUrl"
          }
          else {
            Write-Warning "Sync-DevRepos: failed to update remote for $RepoName (soft fail)"
          }
        }
      }
      catch {
        Write-Warning "Sync-DevRepos: error checking remote for $RepoName : $_"
      }

      # Ensure direct submodules are initialized.
      try {
        $gitmodulesPath = Join-Path -Path $RepoTarget -ChildPath '.gitmodules'
        if (Test-Path -Path $gitmodulesPath) {
          # Parse .gitmodules to find direct submodule paths (no slashes).
          $submodulePaths = @()
          Get-Content -Path $gitmodulesPath | ForEach-Object {
            if ($_ -match '^\s*path\s*=\s*([^\s/]+)\s*$') {
              $submodulePaths += $Matches[1]
            }
          }

          foreach ($submodulePath in $submodulePaths) {
            $submoduleTarget = Join-Path -Path $RepoTarget -ChildPath $submodulePath
            $submoduleGitDir = Join-Path -Path $submoduleTarget -ChildPath '.git'
            if (-not (Test-Path -PathType Container -Path $submoduleGitDir)) {
              & git -C $RepoTarget submodule update --init $submodulePath 2>$null
              if ($LASTEXITCODE -eq 0) {
                Write-Verbose "Sync-DevRepos: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-Warning "Sync-DevRepos: failed to initialize direct submodule $submodulePath in $RepoName (soft fail)"
              }
            }
          }
        }
      }
      catch {
        Write-Warning "Sync-DevRepos: error initializing submodules for $RepoName : $_"
      }

      return
    }

    # Repo not initialized; check if target exists and is non-empty.
    if ((Test-Path -Path $RepoTarget) -and (Get-ChildItem -Path $RepoTarget -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
      Write-Warning "Sync-DevRepos: $RepoTarget exists but is not a git repo (soft fail)"
      return
    }

    # Clone the repository.
    try {
      if (-not (Test-Path -Path $RepoTarget)) {
        New-Item -ItemType Directory -Path $RepoTarget -Force | Out-Null
      }

      & git clone $RepoUrl $RepoTarget 2>$null
      if ($LASTEXITCODE -eq 0) {
        Write-Verbose "Sync-DevRepos: cloned $RepoName to $RepoTarget"

        # Initialize direct submodules after clone.
        try {
          $gitmodulesPath = Join-Path -Path $RepoTarget -ChildPath '.gitmodules'
          if (Test-Path -Path $gitmodulesPath) {
            $submodulePaths = @()
            Get-Content -Path $gitmodulesPath | ForEach-Object {
              if ($_ -match '^\s*path\s*=\s*([^\s/]+)\s*$') {
                $submodulePaths += $Matches[1]
              }
            }

            foreach ($submodulePath in $submodulePaths) {
              & git -C $RepoTarget submodule update --init $submodulePath 2>$null
              if ($LASTEXITCODE -eq 0) {
                Write-Verbose "Sync-DevRepos: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-Warning "Sync-DevRepos: failed to initialize direct submodule $submodulePath in $RepoName (soft fail)"
              }
            }
          }
        }
        catch {
          Write-Warning "Sync-DevRepos: error initializing submodules after clone for $RepoName : $_"
        }
      }
      else {
        Write-Warning "Sync-DevRepos: failed to clone $RepoName from $RepoUrl (soft fail)"
      }
    }
    catch {
      Write-Warning "Sync-DevRepos: error during clone of $RepoName : $_"
    }
  }

  # Provision repositories from the passed list.
  foreach ($repo in $Repositories) {
    if ($null -eq $repo -or $null -eq $repo.name -or $null -eq $repo.target) {
      Write-Warning "Sync-DevRepos: repository entry missing required 'name' or 'target' field (skipping)"
      continue
    }

    $repoName = $repo.name
    $repoTarget = $repo.target

    # Symlink takes precedence over URL.
    if ($null -ne $repo.symlink) {
      New-RepositorySymlink -SymlinkTarget $repo.symlink -SymlinkPath $repoTarget -RepoName $repoName
    }
    elseif ($null -ne $repo.url) {
      Initialize-RepositoryWithSubmodule -RepoUrl $repo.url -RepoTarget $repoTarget -RepoName $repoName
    }
    else {
      Write-Warning "Sync-DevRepos: repository '$repoName' has neither 'symlink' nor 'url' configured (skipping)"
    }
  }

  Write-Verbose "Sync-DevRepos: completed provisioning dev repositories"
}
