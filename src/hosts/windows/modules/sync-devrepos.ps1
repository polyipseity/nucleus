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

function Sync-DevRepo {
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
    Sync-DevRepo -Enabled:$true -Repositories $repos

  .EXAMPLE
    Sync-DevRepo -Enabled:$false
  #>
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter()]
    [object[]]$Repositories = @()
  )

  if (-not $Enabled) {
    Write-Verbose "Sync-DevRepo: provisioning is disabled."
    return
  }

  if ($Repositories.Count -eq 0) {
    Write-Verbose "Sync-DevRepo: no repositories configured for this user."
    return
  }

  $userHome = [Environment]::GetFolderPath('UserProfile')
  $devDir = Join-Path -Path $userHome -ChildPath 'dev'

  # Ensure dev directory exists.
  if (-not (Test-Path -PathType Container -Path $devDir)) {
    try {
      New-Item -ItemType Directory -Path $devDir -Force | Out-Null
      Write-Verbose "Sync-DevRepo: created dev directory at $devDir"
    }
    catch {
      Write-Warning "Sync-DevRepo: failed to create dev directory $devDir : $_"
      return
    }
  }

  # Helper function: create a symlink for a repository.
  function New-RepositorySymlink {
    [CmdletBinding(SupportsShouldProcess)]
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
        if ($PSCmdlet.ShouldProcess($SymlinkPath, "Create symlink to $SymlinkTarget")) {
          New-Item -ItemType SymbolicLink -Path $SymlinkPath -Target $SymlinkTarget -Force -ErrorAction Stop | Out-Null
          Write-Verbose "Sync-DevRepo: created symlink $SymlinkPath -> $SymlinkTarget"
        }
      }
      catch {
        Write-Warning "Sync-DevRepo: failed to create symlink for $RepoName : $_"
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

    # Helper wrapper that captures stdout/stderr together and returns both the
    # command output and success state. This keeps the soft-fail behavior while
    # avoiding hidden git diagnostics.
    function Invoke-GitCommand {
      param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
      )

      $commandOutput = (& git @Arguments 2>&1) | ForEach-Object { [string]$_ }
      $exitCode = $LASTEXITCODE
      [pscustomobject]@{
        Succeeded = ($exitCode -eq 0)
        ExitCode  = $exitCode
        Output    = ($commandOutput -join "`n").Trim()
      }
    }

    # Check if repo is initialized.
    $gitDir = Join-Path -Path $RepoTarget -ChildPath '.git'
    if (Test-Path -PathType Container -Path $gitDir) {
      # Repo already initialized; verify/update remote.
      try {
        $remoteLookup = Invoke-GitCommand -Arguments @('-C', $RepoTarget, 'config', '--get', 'remote.origin.url')
        $currentRemote = $remoteLookup.Output
        if ($currentRemote -ne $RepoUrl) {
          $remoteUpdate = Invoke-GitCommand -Arguments @('-C', $RepoTarget, 'remote', 'set-url', 'origin', $RepoUrl)
          if ($remoteUpdate.Succeeded) {
            Write-Verbose "Sync-DevRepo: updated remote for $RepoName to $RepoUrl"
          }
          else {
            Write-Warning "Sync-DevRepo: failed to update remote for $RepoName (soft fail, exit $($remoteUpdate.ExitCode)): $($remoteUpdate.Output)"
          }
        }
      }
      catch {
        Write-Warning "Sync-DevRepo: error checking remote for $RepoName : $_"
      }

      # Ensure direct submodules are initialized.
      try {
        $gitmodulesPath = Join-Path -Path $RepoTarget -ChildPath '.gitmodules'
        if (Test-Path -Path $gitmodulesPath) {
          # Parse paths from the repository root .gitmodules file. That file
          # already enumerates the direct submodules, and grouped paths such as
          # ext\foo or self\bar are still direct entries in this repo layout.
          $submodulePaths = @()
          Get-Content -Path $gitmodulesPath | ForEach-Object {
            if ($_ -match '^\s*path\s*=\s*(\S+)\s*$') {
              $submodulePaths += $Matches[1]
            }
          }

          foreach ($submodulePath in $submodulePaths) {
            $submoduleTarget = Join-Path -Path $RepoTarget -ChildPath $submodulePath
            $submoduleGitDir = Join-Path -Path $submoduleTarget -ChildPath '.git'
            if (-not (Test-Path -Path $submoduleGitDir)) {
              $submoduleInit = Invoke-GitCommand -Arguments @('-C', $RepoTarget, 'submodule', 'update', '--init', $submodulePath)
              if ($submoduleInit.Succeeded) {
                Write-Verbose "Sync-DevRepo: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-Warning "Sync-DevRepo: failed to initialize direct submodule $submodulePath in $RepoName (soft fail, exit $($submoduleInit.ExitCode)): $($submoduleInit.Output)"
              }
            }
          }
        }
      }
      catch {
        Write-Warning "Sync-DevRepo: error initializing submodules for $RepoName : $_"
      }

      return
    }

    # Repo not initialized; check if target exists and is non-empty.
    $targetHasContents = $false
    if (Test-Path -Path $RepoTarget) {
      try {
        $targetHasContents = (Get-ChildItem -Path $RepoTarget -ErrorAction Stop | Measure-Object).Count -gt 0
      }
      catch {
        Write-Warning "Sync-DevRepo: unable to inspect $RepoTarget before clone (soft fail): $_"
        return
      }
    }
    if ((Test-Path -Path $RepoTarget) -and $targetHasContents) {
      Write-Warning "Sync-DevRepo: $RepoTarget exists but is not a git repo (soft fail)"
      return
    }

    # Clone the repository.
    try {
      if (-not (Test-Path -Path $RepoTarget)) {
        New-Item -ItemType Directory -Path $RepoTarget -Force | Out-Null
      }

      $cloneResult = Invoke-GitCommand -Arguments @('clone', $RepoUrl, $RepoTarget)
      if ($cloneResult.Succeeded) {
        Write-Verbose "Sync-DevRepo: cloned $RepoName to $RepoTarget"

        # Initialize direct submodules after clone.
        try {
          $gitmodulesPath = Join-Path -Path $RepoTarget -ChildPath '.gitmodules'
          if (Test-Path -Path $gitmodulesPath) {
            $submodulePaths = @()
            Get-Content -Path $gitmodulesPath | ForEach-Object {
              if ($_ -match '^\s*path\s*=\s*(\S+)\s*$') {
                $submodulePaths += $Matches[1]
              }
            }

            foreach ($submodulePath in $submodulePaths) {
              $submoduleInit = Invoke-GitCommand -Arguments @('-C', $RepoTarget, 'submodule', 'update', '--init', $submodulePath)
              if ($submoduleInit.Succeeded) {
                Write-Verbose "Sync-DevRepo: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-Warning "Sync-DevRepo: failed to initialize direct submodule $submodulePath in $RepoName (soft fail, exit $($submoduleInit.ExitCode)): $($submoduleInit.Output)"
              }
            }
          }
        }
        catch {
          Write-Warning "Sync-DevRepo: error initializing submodules after clone for $RepoName : $_"
        }
      }
      else {
        Write-Warning "Sync-DevRepo: failed to clone $RepoName from $RepoUrl (soft fail, exit $($cloneResult.ExitCode)): $($cloneResult.Output)"
      }
    }
    catch {
      Write-Warning "Sync-DevRepo: error during clone of $RepoName : $_"
    }
  }

  # Provision repositories from the passed list.
  foreach ($repo in $Repositories) {
    if ($null -eq $repo -or $null -eq $repo.name -or $null -eq $repo.target) {
      Write-Warning "Sync-DevRepo: repository entry missing required 'name' or 'target' field (skipping)"
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
      Write-Warning "Sync-DevRepo: repository '$repoName' has neither 'symlink' nor 'url' configured (skipping)"
    }
  }

  Write-Verbose "Sync-DevRepo: completed provisioning dev repositories"
}
