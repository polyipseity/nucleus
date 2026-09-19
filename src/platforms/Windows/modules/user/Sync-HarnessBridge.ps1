<#
.SYNOPSIS
  Deploys the Windows harness-bridge hook entry points and their PATH shims.

.DESCRIPTION
  The harness bridge answers harness hooks through bare command names
  (`harness-notify`, `harness-approval`) so one shared hook definition works on
  every platform.  Windows reaches them through .cmd shims, because
  %USERPROFILE%\.local\bin is a managed PATH component and a bare name resolves
  through PATHEXT.

  Layout this function converges:

    <USER root>\bin\harness-notify.ps1    deployed copy of the entry point
    <USER root>\bin\harness-approval.ps1  deployed copy of the entry point
    %USERPROFILE%\.local\bin\harness-notify.cmd    shim -> <USER root>\bin copy
    %USERPROFILE%\.local\bin\harness-approval.cmd  shim -> <USER root>\bin copy

  Copies (rather than links into the repository) keep a hook working when the
  checkout moves; they are refreshed whenever the repository copy changes, so the
  repository stays the single source.

  Persistent PATH membership for %USERPROFILE%\.local\bin is owned by
  ManagedPaths.ps1 (pathComponents.Append) and converged by Sync-UserPath.  This
  function only asserts that invariant, so drift surfaces as a warning instead of
  a silently unreachable hook.

.PARAMETER Enabled
  Whether harness-bridge deployment should be enforced.  Mandatory: the caller
  chooses true (deploy) or false (remove shims and deployed copies).

.PARAMETER RepoRoot
  Absolute path to the live repository root.

.PARAMETER UserRoot
  Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

.PARAMETER UserProfile
  Absolute path to the user profile (%USERPROFILE%).

.EXAMPLE
  Sync-HarnessBridge -Enabled:$true -RepoRoot $repoRoot -UserRoot (Get-NucleusUserRoot) -UserProfile $HOME

.EXAMPLE
  Sync-HarnessBridge -Enabled:$false -RepoRoot $repoRoot -UserRoot (Get-NucleusUserRoot) -UserProfile $HOME

.NOTES
  Required preload: ManagedPaths.ps1 (Get-NucleusManagedBinDir) and
  Format-NucleusOutput.psm1 (Write-Nucleus*), both dot-sourced by apply.ps1.

  Exit codes: this function does not emit exit codes; failures are reported as
  warnings.  Deployed hook entry points are best-effort by contract — a missing
  shim only stops remote control, it never blocks a harness session.
#>

function Sync-HarnessBridge {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$UserRoot,

    [Parameter(Mandatory)]
    [string]$UserProfile
  )

  $label = 'harness-bridge'
  $scriptNames = @('harness-approval', 'harness-notify')
  $binDir = Join-Path -Path $UserRoot -ChildPath 'bin'
  $shimDir = Join-Path -Path $UserProfile -ChildPath '.local\bin'

  try {
    if (-not $Enabled) {
      foreach ($scriptName in $scriptNames) {
        foreach ($managedPath in @(
            (Join-Path -Path $shimDir -ChildPath "$scriptName.cmd"),
            (Join-Path -Path $binDir -ChildPath "$scriptName.ps1")
          )) {
          if (Test-Path -LiteralPath $managedPath) {
            Remove-Item -LiteralPath $managedPath -Force
            Write-NucleusNotice -Message "[$label] removed $managedPath"
          }
        }
      }
      Write-NucleusNotice -Message "[$label] disabled — harness hooks answer locally"
      return
    }

    $managedShimDir = Get-NucleusManagedBinDir -Name 'local'
    if ($managedShimDir -ne $shimDir) {
      Write-NucleusWarning -Message "[$label] shim directory '$shimDir' differs from the managed PATH component '$managedShimDir'"
    }

    $null = New-Item -ItemType Directory -Path $binDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    $null = New-Item -ItemType Directory -Path $shimDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

    $shimTemplatePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\harness-bridge-shim.cmd'
    if (-not (Test-Path -LiteralPath $shimTemplatePath -PathType Leaf)) {
      Write-NucleusWarning -Message "[$label] shim template not found: $shimTemplatePath"
      return
    }
    $shimTemplate = Get-Content -LiteralPath $shimTemplatePath -Raw -Encoding UTF8

    foreach ($scriptName in $scriptNames) {
      $sourcePath = Join-Path -Path $RepoRoot -ChildPath "src\scripts\notify\$scriptName.ps1"
      if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-NucleusWarning -Message "[$label] entry point not found: $sourcePath"
        continue
      }

      $targetPath = Join-Path -Path $binDir -ChildPath "$scriptName.ps1"
      $needsCopy = $true
      if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $needsCopy = (Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8) -ne (Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8)
      }
      if ($needsCopy) {
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        Write-NucleusNotice -Message "[$label] deployed $targetPath"
      }

      # WHY: .gitattributes marks *.bat and *.ps1 but not *.cmd, so the template
      # arrives with LF endings while cmd.exe expects CRLF.
      $shim = ($shimTemplate -replace '__HARNESS_BRIDGE_SCRIPT__', $targetPath) -replace "`r?`n", "`r`n"
      $shimPath = Join-Path -Path $shimDir -ChildPath "$scriptName.cmd"
      $shimNeedsWrite = $true
      if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
        $shimNeedsWrite = (Get-Content -LiteralPath $shimPath -Raw -Encoding UTF8) -ne $shim
      }
      if ($shimNeedsWrite) {
        [System.IO.File]::WriteAllText($shimPath, $shim, [System.Text.UTF8Encoding]::new($false))
        Write-NucleusNotice -Message "[$label] wrote $shimPath"
      }
    }
  }
  catch {
    Write-NucleusWarning -Message "[$label] $($_.Exception.Message)"
  }
}
