<#
.SYNOPSIS
  Provisions the managed harness Python venv and its pinned PyYAML dependency.
.DESCRIPTION
  Creates <USER root>\envs\harness-python with uv when the interpreter is
  missing, installs the PyYAML version pinned in src/lockfiles/lockfile.json,
  and prepends the venv Scripts directory to the current session PATH. A
  missing uv, missing pin, or failed uv call is a hard error. No package is
  installed into the system interpreter or into the global uv tool set.
.PARAMETER LockfilePath
  Overrides the lockfile path. Used by tests with a synthetic repo tree.
.PARAMETER UserRoot
  Overrides the nucleus USER root. Used by tests so the real venv is untouched.
.PARAMETER UvPath
  Overrides the uv executable path. Used by tests with a recording shim.
.OUTPUTS
  PSCustomObject with VenvPython, VenvScriptsDir and PyYamlVersion.
.EXAMPLE
  Invoke-HarnessPythonSetup
#>

. (Join-Path -Path $PSScriptRoot -ChildPath '..\ManagedPaths.ps1')

function Invoke-HarnessPythonSetup {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [string]$LockfilePath,
    [string]$UserRoot,
    [string]$UvPath
  )

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..')).Path
  }
  $lockPath = if ($PSBoundParameters.ContainsKey('LockfilePath')) { $LockfilePath } else { Join-Path -Path $repoRoot -ChildPath 'src\lockfiles\lockfile.json' }
  if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    $message = "lockfile not found at '$lockPath'"
    Write-NucleusError -CommandName 'Invoke-HarnessPythonSetup' $message
    throw $message
  }

  $lockfile = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $pyYamlVersion = $lockfile.uv.pyyaml
  if ($pyYamlVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($pyYamlVersion)) {
    $message = "lockfile uv.pyyaml pin is missing at '$lockPath'"
    Write-NucleusError -CommandName 'Invoke-HarnessPythonSetup' $message
    throw $message
  }

  if ($PSBoundParameters.ContainsKey('UvPath')) {
    if (-not (Test-Path -LiteralPath $UvPath -PathType Leaf)) {
      $message = "uv executable not found at '$UvPath'"
      Write-NucleusError -CommandName 'Invoke-HarnessPythonSetup' $message
      throw $message
    }
  } else {
    # Resolve the executable from PATH directly. Get-Command keeps a session
    # cache, and a stale cache entry would hide the uv installed earlier in the
    # same bootstrap process.
    $uvPath = $null
    foreach ($directory in ($env:PATH -split [System.IO.Path]::PathSeparator)) {
      if ([string]::IsNullOrWhiteSpace($directory)) { continue }
      foreach ($name in @('uv.exe', 'uv.cmd', 'uv.ps1', 'uv')) {
        $candidate = Join-Path -Path $directory -ChildPath $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $uvPath = $candidate
          break
        }
      }
      if ($uvPath) { break }
    }
  }
  if (-not $uvPath) {
    $message = 'uv not found on PATH; install uv before setting up the harness Python venv'
    Write-NucleusError -CommandName 'Invoke-HarnessPythonSetup' $message
    throw $message
  }

  $venvPython = if ($PSBoundParameters.ContainsKey('UserRoot')) {
    Get-NucleusHarnessPythonExe -UserRoot $UserRoot
  } else {
    Get-NucleusHarnessPythonExe
  }
  $venvScriptsDir = Split-Path -Path $venvPython -Parent
  $venvDir = Split-Path -Path $venvScriptsDir -Parent
  if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Path $venvDir -Parent) -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded before uv creates the venv
    $global:LASTEXITCODE = 0
    & $uvPath venv $venvDir
    if ($LASTEXITCODE -ne 0) {
      $message = "'uv venv $venvDir' failed (exit $LASTEXITCODE)"
      Write-NucleusError -CommandName 'uv' $message
      throw $message
    }
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
      $message = "uv venv did not create '$venvPython'"
      Write-NucleusError -CommandName 'Invoke-HarnessPythonSetup' $message
      throw $message
    }
  }

  $installSpec = "pyyaml==$pyYamlVersion"
  $global:LASTEXITCODE = 0
  & $uvPath pip install --python $venvPython $installSpec
  if ($LASTEXITCODE -ne 0) {
    $message = "'uv pip install --python $venvPython $installSpec' failed (exit $LASTEXITCODE)"
    Write-NucleusError -CommandName 'uv' $message
    throw $message
  }

  Add-NucleusPathEntry -Path $venvScriptsDir -Position Prepend
  return [PSCustomObject]@{
    VenvPython     = $venvPython
    VenvScriptsDir = $venvScriptsDir
    PyYamlVersion  = $pyYamlVersion
  }
}
