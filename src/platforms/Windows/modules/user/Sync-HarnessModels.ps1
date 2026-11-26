. (Join-Path -Path $PSScriptRoot -ChildPath '..\ManagedPaths.ps1')

function Resolve-HarnessPythonExe {
  <#
  .SYNOPSIS
    Resolves the Python interpreter used by the harness model merge tool.

  .DESCRIPTION
    The uv venv under the nucleus USER root is the only interpreter with the
    pinned PyYAML, so it wins before PATH. When the venv is absent, the first
    python3.exe or python.exe on PATH is used and the function boundary keeps
    absence stub-able for tests.
  #>
  [CmdletBinding()]
  [OutputType([object])]
  param()

  # WHY: outside Windows the managed USER root may be undefined, which is the
  # same as having no managed venv for this resolver.
  $managedPython = try { Get-NucleusHarnessPythonExe } catch { $null }
  if (-not [string]::IsNullOrWhiteSpace($managedPython) -and
    (Test-Path -LiteralPath $managedPython -PathType Leaf)) {
    return $managedPython
  }

  $commands = @(
    Get-Command -Name 'python3.exe' -CommandType Application -ErrorAction SilentlyContinue # check-suppress:suppression_doc: probe optional interpreter name on PATH; absence is a hard error in the caller
    Get-Command -Name 'python.exe' -CommandType Application -ErrorAction SilentlyContinue # check-suppress:suppression_doc: probe optional interpreter name on PATH; absence is a hard error in the caller
  )
  if ($commands.Count -eq 0) {
    return $null
  }
  return $commands[0].Source
}

# File name is fixed by the provisioning contract; the exported function uses
# the singular noun required by PSScriptAnalyzer.
function Sync-HarnessModel {
  <#
  .SYNOPSIS
    Merges LiteLLM model slots into installed harness configs on Windows.

  .DESCRIPTION
    Windows twin of the POSIX provision-harness-models activation. The registry
    is the single list of harnesses and target paths. A harness with no config
    directory is reported and skipped; a missing interpreter, registry, or merge
    tool is a hard error. No directory is created for an absent harness.

  .PARAMETER Enabled
    Whether harness model provisioning is managed in this apply.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository checkout.

  .PARAMETER PythonExe
    Python interpreter path. When empty, the managed harness venv interpreter
    is used, falling back to the first python3.exe or python.exe on PATH.

  .PARAMETER HostName
    Host key used to select a host-split config path from the registry.

  .PARAMETER HomeDirectory
    Home directory used to expand registry paths that start with a tilde.

  .EXAMPLE
    Sync-HarnessModel -Enabled:$true -RepoRoot 'C:\repos\nucleus' -PythonExe 'C:\Python\python.exe' -HostName 'Windows' -HomeDirectory 'C:\Users\admin'
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [string]$HomeDirectory
  )

  $label = 'harness-models'
  if (-not $Enabled) {
    Write-NucleusNotice -CommandName $label 'disabled - skipping harness model provisioning'
    return
  }

  $effectivePython = $PythonExe
  if ([string]::IsNullOrWhiteSpace($effectivePython)) {
    $effectivePython = [string](Resolve-HarnessPythonExe)
  }
  if ([string]::IsNullOrWhiteSpace($effectivePython) -or -not (Test-Path -LiteralPath $effectivePython -PathType Leaf)) {
    Write-NucleusError -CommandName $label "python interpreter not found: $effectivePython"
    throw "python interpreter not found: $effectivePython"
  }

  $registryPath = Join-Path -Path $RepoRoot -ChildPath 'src\modules\configs\harness-models.json'
  if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    Write-NucleusError -CommandName $label "registry not found: $registryPath"
    throw "registry not found: $registryPath"
  }

  $toolPath = Join-Path -Path $RepoRoot -ChildPath 'src\scripts\agents\merge-harness-models.py'
  if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    Write-NucleusError -CommandName $label "merge tool not found: $toolPath"
    throw "merge tool not found: $toolPath"
  }

  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
  $installed = @()
  foreach ($entry in $registry.harnesses) {
    $configuredPath = [string]$entry.path
    if ($entry.path -is [System.Management.Automation.PSCustomObject]) {
      $hostProperty = $entry.path.PSObject.Properties[$HostName]
      if ($null -eq $hostProperty) {
        throw "harness $($entry.harness) has no config path for host $HostName"
      }
      $configuredPath = [string]$hostProperty.Value
    }
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
      throw "harness $($entry.harness) has no config path for host $HostName"
    }

    if ($configuredPath.StartsWith('~/')) {
      $relativePath = $configuredPath.Substring(2) -replace '/', [System.IO.Path]::DirectorySeparatorChar
      $configFile = Join-Path -Path $HomeDirectory -ChildPath $relativePath
    }
    else {
      $configFile = $configuredPath
    }
    $configDir = Split-Path -Path $configFile -Parent
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
      # WHY: a harness whose install is disabled has no config directory. Creating one here would leave an empty stub that makes that harness look configured.
      Write-NucleusNotice -CommandName $label "skipped $($entry.harness): no config directory $configDir"
      continue
    }
    $installed += [string]$entry.harness
  }

  if ($installed.Count -eq 0) {
    Write-NucleusNotice -CommandName $label 'no installed harness config directories; skipped model provisioning'
    return
  }

  $mergeArgs = @(
    $toolPath
    '--registry', $registryPath
    '--repo-root', $RepoRoot
    '--home', $HomeDirectory
    '--host', $HostName
  )
  foreach ($harnessId in $installed) {
    $mergeArgs += @('--harness', $harnessId)
  }
  # WHY: a previous native command may have left a non-zero LASTEXITCODE, and
  # a script-based interpreter stub need not set it on a successful exit.
  $global:LASTEXITCODE = 0
  & $effectivePython @mergeArgs
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError -CommandName $label "merge-harness-models exited $LASTEXITCODE"
    throw "merge-harness-models exited $LASTEXITCODE"
  }
  Write-NucleusInfo -CommandName $label "merged model slots for $($installed.Count) harness(es)"
}
