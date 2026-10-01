function Sync-DevRepoCatalog {
  <#
  .SYNOPSIS
    Provision development repositories in ~/dev on Windows.

  .DESCRIPTION
    Populates ~/dev with repositories from the -Repositories parameter, which
    comes from the centralized user registry. Each entry carries either a symlink
    or a Git URL, and symlink wins when both are present.

    All operations soft-fail: missing repos and clone failures log warnings
    without halting provisioning.

  .PARAMETER Enabled
    Whether dev repos should be provisioned. Apply.ps1 reads this from the user
    registry (users.json) so enable status derives from centralized configuration
    rather than an implicit username check.

  .PARAMETER Repositories
    Array of repository objects from the user registry, each with name (string,
    for logging), target (string, e.g. dev\myrepo), and optionally symlink or url.
    An entry with neither is skipped with a warning.

  .NOTES
    Environment variables: USERDOMAIN, USERNAME, used for delete-protection ACLs.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter()]
    [object[]]$Repositories = @()
  )

  if (-not $Enabled) {
    Write-Verbose "Sync-DevRepoCatalog: provisioning is disabled."
    return
  }

  if ($Repositories.Count -eq 0) {
    Write-Verbose "Sync-DevRepoCatalog: no repositories configured for this user."
    return
  }

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  $userHome = [Environment]::GetFolderPath('UserProfile')
  $devDir = Join-Path -Path $userHome -ChildPath 'dev'

  # Ensure dev directory exists.
  if (-not (Test-Path -PathType Container -Path $devDir)) {
    try {
      New-Item -ItemType Directory -Path $devDir -Force > $null
      Write-Verbose "Sync-DevRepoCatalog: created dev directory at $devDir"
    }
    catch {
      Write-NucleusError -CommandName 'Sync-DevRepoCatalog' "failed to create dev directory $devDir : $_"
      throw
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
        # a symlink requires admin or developer mode on Windows 10+
        if ($PSCmdlet.ShouldProcess($SymlinkPath, "Create symlink to $SymlinkTarget")) {
          New-Item -ItemType SymbolicLink -Path $SymlinkPath -Target $SymlinkTarget -Force -ErrorAction Stop > $null
          Set-ManagedSymlinkDeleteProtection -Context "Sync-DevRepoCatalog" -Path $SymlinkPath
          Write-Verbose "Sync-DevRepoCatalog: created symlink $SymlinkPath -> $SymlinkTarget"
        }
      }
      catch {
        throw "Sync-DevRepoCatalog failed to create symlink for $RepoName : $_"
      }
    }
  }

  # Verifies the remote and initializes direct submodules.
  function Initialize-RepositoryWithSubmodule {
    param(
      [Parameter(Mandatory = $true)]
      [string]$RepoUrl,

      [Parameter(Mandatory = $true)]
      [string]$RepoTarget,

      [Parameter(Mandatory = $true)]
      [string]$RepoName
    )

    # WHY: capturing both streams keeps the soft-fail behavior without hiding git
    # diagnostics.
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
            Write-Verbose "Sync-DevRepoCatalog: updated remote for $RepoName to $RepoUrl"
          }
          else {
            Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "failed to update remote for $RepoName (soft fail, exit $($remoteUpdate.ExitCode)): $($remoteUpdate.Output)"
          }
        }
      }
      catch {
        Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "error checking remote for $RepoName : $_"
      }

      # Ensure direct submodules are initialized.
      try {
        $gitmodulesPath = Join-Path -Path $RepoTarget -ChildPath '.gitmodules'
        if (Test-Path -Path $gitmodulesPath) {
          # The root .gitmodules already enumerates the direct submodules, and grouped
          # paths such as ext\foo or self\bar are still direct entries here.
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
                Write-Verbose "Sync-DevRepoCatalog: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "failed to initialize direct submodule $submodulePath in $RepoName (soft fail, exit $($submoduleInit.ExitCode)): $($submoduleInit.Output)"
              }
            }
          }
        }
      }
      catch {
        Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "error initializing submodules for $RepoName : $_"
      }

      return
    }

    # A non-empty target blocks the clone
    $targetHasContents = $false
    if (Test-Path -Path $RepoTarget) {
      try {
        $targetHasContents = (Get-ChildItem -Path $RepoTarget -ErrorAction Stop | Measure-Object).Count -gt 0
      }
      catch {
        Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "unable to inspect $RepoTarget before clone (soft fail): $_"
        return
      }
    }
    if ((Test-Path -Path $RepoTarget) -and $targetHasContents) {
      Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "$RepoTarget exists but is not a git repo (soft fail)"
      return
    }

    # Clone the repository.
    try {
      if (-not (Test-Path -Path $RepoTarget)) {
        New-Item -ItemType Directory -Path $RepoTarget -Force > $null
      }

      $cloneResult = Invoke-GitCommand -Arguments @('clone', $RepoUrl, $RepoTarget)
      if ($cloneResult.Succeeded) {
        Write-Verbose "Sync-DevRepoCatalog: cloned $RepoName to $RepoTarget"

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
                Write-Verbose "Sync-DevRepoCatalog: initialized direct submodule $submodulePath in $RepoName"
              }
              else {
                Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "failed to initialize direct submodule $submodulePath in $RepoName (soft fail, exit $($submoduleInit.ExitCode)): $($submoduleInit.Output)"
              }
            }
          }
        }
        catch {
          Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "error initializing submodules after clone for $RepoName : $_"
        }
      }
      else {
        Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "failed to clone $RepoName from $RepoUrl (soft fail, exit $($cloneResult.ExitCode)): $($cloneResult.Output)"
      }
    }
    catch {
      Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "error during clone of $RepoName : $_"
    }
  }

  # Provision repositories from the passed list.
  foreach ($repo in $Repositories) {
    if ($null -eq $repo -or $null -eq $repo.name -or $null -eq $repo.target) {
      Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "repository entry missing required 'name' or 'target' field (skipping)"
      continue
    }

    $repoName = $repo.name
    $repoTarget = $repo.target

    # symlink wins over url
    if ($null -ne $repo.symlink) {
      New-RepositorySymlink -SymlinkTarget $repo.symlink -SymlinkPath $repoTarget -RepoName $repoName
    }
    elseif ($null -ne $repo.url) {
      Initialize-RepositoryWithSubmodule -RepoUrl $repo.url -RepoTarget $repoTarget -RepoName $repoName
    }
    else {
      Write-NucleusWarning -CommandName 'Sync-DevRepoCatalog' "repository '$repoName' has neither 'symlink' nor 'url' configured (skipping)"
    }
  }

  Write-Verbose "Sync-DevRepoCatalog: completed provisioning dev repositories"
}
