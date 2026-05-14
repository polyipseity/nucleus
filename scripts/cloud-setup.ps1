<#
.SYNOPSIS
  Guides one-time cloud remote setup and converges cloud mount automation.

.DESCRIPTION
  Performs a bounded cloud-drive setup workflow:
    1. verifies required rclone remotes exist (GoogleDrive, OneDrive)
    2. launches interactive `rclone config` if remotes are missing
    3. runs `nix run <repo>/src#apply` so cloud mount services converge

.PARAMETER SkipApply
  Validate/setup remotes only; do not run apply.

.EXAMPLE
  .\cloud-setup.ps1

.EXAMPLE
  .\cloud-setup.ps1 -SkipApply
#>
[CmdletBinding()]
param(
  [switch]$SkipApply
)

$ErrorActionPreference = 'Stop'

function Resolve-NucleusRoot {
  $configPath = Join-Path $HOME '.config\nucleus\repo-root'
  if (Test-Path -Path $configPath -PathType Leaf) {
    $configuredRoot = (Get-Content -Path $configPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and (Test-Path -Path $configuredRoot -PathType Container)) {
      return $configuredRoot
    }
  }

  # git rev-parse stderr is suppressed because running outside a git checkout
  # is expected and benign here; the result is validated before use.
  $gitRoot = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String).Trim()
  if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -Path $gitRoot -PathType Container)) {
    return $gitRoot
  }

  return (Join-Path $HOME 'dev\nucleus')
}

function Get-RcloneMissingRemote {
  param(
    [Parameter(Mandatory)]
    [string[]]$RequiredRemotes
  )

  # listremotes stderr is suppressed because missing/first-run configs may emit
  # expected setup hints; caller checks for null output and handles failure.
  $listed = & rclone listremotes 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  $missing = @()
  foreach ($remote in $RequiredRemotes) {
    if (-not ($listed -contains "${remote}:")) {
      $missing += $remote
    }
  }

  return $missing
}

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
  throw 'cloud-setup: rclone not found on PATH. Run apply/bootstrap first, then retry.'
}

$requiredRemotes = @('GoogleDrive', 'OneDrive')
$missingRemotes = Get-RcloneMissingRemote -RequiredRemotes $requiredRemotes
if ($null -eq $missingRemotes) {
  throw "cloud-setup: failed to read rclone remotes. Run 'rclone config' manually and retry."
}

if ($missingRemotes.Count -gt 0) {
  Write-Output "cloud-setup: missing rclone remotes: $($missingRemotes -join ', ')"
  Write-Output 'cloud-setup: launching interactive rclone configuration...'
  & rclone config

  $missingRemotes = Get-RcloneMissingRemote -RequiredRemotes $requiredRemotes
  if ($null -eq $missingRemotes) {
    throw 'cloud-setup: failed to re-read rclone remotes after configuration.'
  }
}

if ($missingRemotes.Count -gt 0) {
  throw "cloud-setup: required remotes are still missing: $($missingRemotes -join ', '). Rerun after completing those remotes in rclone config."
}

Write-Output 'cloud-setup: required remotes are configured.'

if (-not $SkipApply) {
  $repoRoot = Resolve-NucleusRoot
  Write-Output 'cloud-setup: running nucleus apply to converge cloud mount services...'
  & nix run "$repoRoot/src#apply"
  if ($LASTEXITCODE -ne 0) {
    throw "cloud-setup: apply failed with exit code $LASTEXITCODE"
  }
}

Write-Output "$($PSStyle.Foreground.Green)cloud-setup: setup complete$($PSStyle.Reset)"
