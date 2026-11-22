# Bundle freshness: tell the operator when the running bundle predates the tree.
#
# WHY this exists: nucleus-check and nucleus-test are Nix store bundles built at
# apply time. Running one against a newer working tree reports the deployed code,
# not the tree, so a policy violation already fixed at HEAD reads as a live
# failure. nucleus-apply already records the revision it deployed in its apply
# history, so this lib reads that record rather than adding a second mechanism.
#Requires -Version 5.1

Set-StrictMode -Version Latest

if (-not (Get-Variable -Name '_NUCLEUS_BUNDLE_FRESHNESS_SOURCED' -Scope Script -ErrorAction SilentlyContinue)) { # check-suppress:suppression_doc: source guard probe for a variable that may not exist yet
  $script:_NUCLEUS_BUNDLE_FRESHNESS_SOURCED = $true
} else {
  return
}

# Test seams: set by Pester tests to drive both revisions without a host.
if (-not (Get-Variable -Name 'BfStubAppliedRev' -Scope Script -ErrorAction SilentlyContinue)) { # check-suppress:suppression_doc: test-seam variable may not exist before first source
  $script:BfStubAppliedRev = $null
}
if (-not (Get-Variable -Name 'BfStubHeadRev' -Scope Script -ErrorAction SilentlyContinue)) { # check-suppress:suppression_doc: test-seam variable may not exist before first source
  $script:BfStubHeadRev = $null
}
if (-not (Get-Variable -Name '_NUCLEUS_BUNDLE_FRESHNESS_NOTICED' -Scope Script -ErrorAction SilentlyContinue)) { # check-suppress:suppression_doc: process-once guard variable may not exist before first source
  $script:_NUCLEUS_BUNDLE_FRESHNESS_NOTICED = $false
}

. (Join-Path $PSScriptRoot 'apply-history.ps1')

function Get-BundleFreshnessAppliedRev {
  <#
  .SYNOPSIS
    Returns the newest successful apply commit hash, or an empty string.
  .DESCRIPTION
    Reads the stub seam first so a test can drive it without a host. Newest
    success wins: a later failed apply deployed nothing.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ($null -ne $script:BfStubAppliedRev) {
    return [string]$script:BfStubAppliedRev
  }
  if (-not [string]::IsNullOrEmpty($env:NUCLEUS_BF_STUB_APPLIED_REV)) {
    return [string]$env:NUCLEUS_BF_STUB_APPLIED_REV
  }

  $histPath = Get-ApplyHistoryPath
  if (-not (Test-Path -LiteralPath $histPath)) {
    Write-Verbose "bundle-freshness: no apply history at $histPath"
    return ''
  }

  try {
    $json = Get-ApplyHistoryEntriesJson
  } catch {
    # WHY: corrupt or unreadable history must not fail the pipeline; record why and stay silent.
    Write-Verbose "bundle-freshness: could not read apply history: $($_.Exception.Message)"
    return ''
  }

  try {
    $obj = $json | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Verbose "bundle-freshness: could not parse apply history JSON: $($_.Exception.Message)"
    return ''
  }

  $entries = @($obj.entries)
  foreach ($entry in $entries) {
    $result = $entry.result
    if ($result -eq 'success') {
      $commitHash = $entry.commitHash
      if ($null -eq $commitHash) { return '' }
      $commitHashText = [string]$commitHash
      if ([string]::IsNullOrWhiteSpace($commitHashText)) { return '' }
      return $commitHashText
    }
  }

  Write-Verbose 'bundle-freshness: no successful apply entry found in history'
  return ''
}

function Get-BundleFreshnessHeadRev {
  <#
  .SYNOPSIS
    Returns the working tree's short HEAD revision, or an empty string.
  .DESCRIPTION
    Resolved through the repository root, never from the bundle's own location:
    the bundle lives in the Nix store, which is not a git repository.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ($null -ne $script:BfStubHeadRev) {
    return [string]$script:BfStubHeadRev
  }
  if (-not [string]::IsNullOrEmpty($env:NUCLEUS_BF_STUB_HEAD_REV)) {
    return [string]$env:NUCLEUS_BF_STUB_HEAD_REV
  }

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot) -or -not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    Write-Verbose 'bundle-freshness: NUCLEUS_REPO_ROOT is not set to a directory; skipping HEAD comparison'
    return ''
  }

  $gitExe = Get-Command git -ErrorAction SilentlyContinue # check-suppress:suppression_doc: git is optional for bundle freshness notice
  if (-not $gitExe) {
    Write-Verbose 'bundle-freshness: git not found; skipping HEAD comparison'
    return ''
  }

  try {
    $head = (& git -C $repoRoot rev-parse --short HEAD 2>$null) # check-suppress:suppression_doc: best-effort git probe; missing repo or HEAD must not fail the pipeline
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
      Write-Verbose "bundle-freshness: could not resolve HEAD in $repoRoot"
      return ''
    }
    return ([string]$head).Trim()
  } catch {
    Write-Verbose "bundle-freshness: git HEAD probe failed: $($_.Exception.Message)"
    return ''
  }
}

function Write-BundleFreshnessNotice {
  <#
  .SYNOPSIS
    Emits one notice when the deployed bundle trails the working tree.
  .DESCRIPTION
    Never fails the caller: this is advice, and a missing history or a missing
    git must not turn a passing pipeline into a failing one.
    Emits at most once per process.
  #>
  [CmdletBinding()]
  param()

  if ($script:_NUCLEUS_BUNDLE_FRESHNESS_NOTICED) {
    return
  }

  $applied = Get-BundleFreshnessAppliedRev
  if ([string]::IsNullOrWhiteSpace($applied)) {
    return
  }

  $head = Get-BundleFreshnessHeadRev
  if ([string]::IsNullOrWhiteSpace($head)) {
    return
  }

  if ($applied -eq $head) {
    return
  }

  $message = "this bundle was built by an apply at $applied, but the tree is at $head ($applied is older). Run nucleus-apply to test what is in the tree."
  if (Get-Command Write-NucleusNotice -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: notice helper is optional when Format-NucleusOutput is not imported
    Write-NucleusNotice -Message $message
  } else {
    Write-Information "[notice] $message" -InformationAction Continue
  }
  $script:_NUCLEUS_BUNDLE_FRESHNESS_NOTICED = $true
}
