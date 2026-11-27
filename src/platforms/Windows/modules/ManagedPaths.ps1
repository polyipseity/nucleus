<#
.SYNOPSIS
  Canonical Windows-side declaration of managed PATH directories.

.DESCRIPTION
  Mirrors pathComponents in src/modules/lib/managed-paths.nix: that file is the
  authoritative cross-platform source; this module is the Windows-side
  consumer equivalent.  Every PowerShell script that needs to prepend managed
  bin directories should reference the variables or function here rather than
  hardcoding the path strings.

  Variables are scoped script: to prevent leaks when dot-sourced.

  $script:nucleusPathComponents: hash table with Prepend/Append arrays (relative)
  $script:nucleusPrependRegistry: registry-format paths (%USERPROFILE%-prefixed)
  Get-NucleusManagedBinDir: resolves a single bin dir by component name
#>

# Canonical source: src/modules/lib/managed-paths.nix (pathComponents)
$script:nucleusPathComponents = @{
  Prepend = @()  # before system default PATH; Append entries go after system default PATH
  Append  = @(
    '.bun\bin'
    '.cargo\bin'
    '.local\bin'
  )
}

# Registry-format %USERPROFILE%-prefixed paths (REG_EXPAND_SZ) for HKLM Path.
# Used by Sync-UserPath.ps1.
# Elements already include \bin suffix, so just prefix with %USERPROFILE%.
$script:nucleusPrependRegistry = $script:nucleusPathComponents.Prepend | ForEach-Object {
  "%USERPROFILE%$_"
}

# Append-side counterpart for HKLM Path append entries.
$script:nucleusAppendRegistry = $script:nucleusPathComponents.Append | ForEach-Object {
  "%USERPROFILE%$_"
}

<#
.SYNOPSIS
  Resolves a single managed bin directory by component name.
.DESCRIPTION
  Returns the full path to a managed bin directory (e.g. "Join-Path $HOME '.bun\bin'").
  The component name is the short name without the leading dot or trailing \bin
  suffix: "bun", "cargo", or "local".
.PARAMETER Name
  Component name: "bun", "cargo", or "local".
.EXAMPLE
  Get-NucleusManagedBinDir "bun" -> C:\Users\user\.bun\bin
#>
function Get-NucleusManagedBinDir {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('bun', 'cargo', 'local')]
    [string]$Name
  )
  Join-Path -Path $HOME -ChildPath ".${Name}\bin"
}

<#
.SYNOPSIS
  Returns the path to the Scoop shims directory.
.DESCRIPTION
  Returns the full path to the Scoop shims directory (%USERPROFILE%\scoop\shims).
.EXAMPLE
  Get-NucleusScoopShimsDir -> C:\Users\user\scoop\shims
#>
function Get-NucleusScoopShimsDir {
  [CmdletBinding()]
  param()
  Join-Path -Path $env:USERPROFILE -ChildPath "scoop\shims"
}

<#
.SYNOPSIS
  Returns the path to the LLVM bin directory.
.DESCRIPTION
  Returns the full path to the LLVM bin directory (C:\Program Files\LLVM\bin).
.EXAMPLE
  Get-NucleusLLVMBinDir -> C:\Program Files\LLVM\bin
#>
function Get-NucleusLLVMBinDir {
  [CmdletBinding()]
  [OutputType([string])]
  param()
  "C:\Program Files\LLVM\bin"
}

<#
.SYNOPSIS
  Returns the path to the nucleus USER root.
.DESCRIPTION
  Mirrors derive_nucleus_user_root in src/scripts/lib/lib.sh: the nucleus USER
  root is %LOCALAPPDATA%\nucleus on Windows (~/Library/Application Support/nucleus
  on macOS, ~/.local/share/nucleus on NixOS).  Scripts must call this instead of
  hardcoding the path.
.OUTPUTS
  System.String.  Absolute path to the USER root.
.EXAMPLE
  Get-NucleusUserRoot -> C:\Users\admin\AppData\Local\nucleus
#>
function Get-NucleusUserRoot {
  [CmdletBinding()]
  [OutputType([string])]
  param()
  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'Get-NucleusUserRoot: %LOCALAPPDATA% is unset; the nucleus USER root is undefined on this host'
  }
  Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus'
}

<#
.SYNOPSIS
  Returns the managed harness Python interpreter under the nucleus USER root.
.DESCRIPTION
  The interpreter lives in a uv-managed venv at
  <USER root>\envs\harness-python. Consumers must probe this path before
  PATH so a stale system Python cannot replace the pinned PyYAML runtime.
.PARAMETER UserRoot
  Overrides the nucleus USER root for tests that must not touch the host root.
.OUTPUTS
  System.String.  Absolute path to the managed harness python.exe.
.EXAMPLE
  Get-NucleusHarnessPythonExe -> C:\Users\admin\AppData\Local\nucleus\envs\harness-python\Scripts\python.exe
#>
function Get-NucleusHarnessPythonExe {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [string]$UserRoot
  )
  $root = if ($PSBoundParameters.ContainsKey('UserRoot')) { $UserRoot } else { Get-NucleusUserRoot }
  Join-Path -Path $root -ChildPath 'envs\harness-python\Scripts\python.exe'
}

function Resolve-HarnessPythonExe {
  <#
  .SYNOPSIS
    Resolves the Python interpreter used by the harness model merge tool.

  .DESCRIPTION
    The uv venv under the nucleus USER root is the only interpreter with the
    pinned PyYAML, so it wins before PATH. When the venv is absent, the first
    python3.exe or python.exe on PATH is used and the function boundary keeps
    absence stub-able for tests.
  .OUTPUTS
    The resolved Python interpreter path, or $null when no interpreter exists.
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

function Get-NucleusBunExecutable {
  <#
  .SYNOPSIS
    Finds the bun executable installed on this host.

  .DESCRIPTION
    WinGet adds bun's directory to the persisted User or Machine PATH, but an
    apply process started before that install keeps its old process PATH.
    Searching the persisted scopes finds the binary the install actually placed.
    A supplied -SearchPath makes the resolver testable without reading the host
    registry. No candidate means no executable, never an invented path.

  .PARAMETER SearchPath
    Directories to search instead of the persisted scopes. Optional.

  .PARAMETER PersistedPath
    Semicolon-delimited Machine and User PATH strings to search instead of the
    host registry values. Optional. Each value is split into directories before
    probing, matching how persisted PATH stores multiple entries.

  .OUTPUTS
    System.String. Full path to the bun executable, or $null when none is found.

  .EXAMPLE
    Get-NucleusBunExecutable

  .EXAMPLE
    Get-NucleusBunExecutable -SearchPath 'C:\Tools\bun'
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter()]
    [string[]]$SearchPath,

    [Parameter()]
    [string[]]$PersistedPath
  )

  if ($PSBoundParameters.ContainsKey('SearchPath') -and $PSBoundParameters.ContainsKey('PersistedPath')) {
    throw 'SearchPath and PersistedPath are mutually exclusive'
  }

  $candidatePaths = if ($PSBoundParameters.ContainsKey('SearchPath')) {
    @($SearchPath)
  } elseif ($IsWindows) {
    $persistedPaths = if ($PSBoundParameters.ContainsKey('PersistedPath')) {
      @($PersistedPath)
    } else {
      @(
        ([Environment]::GetEnvironmentVariable('Path', 'Machine')),
        ([Environment]::GetEnvironmentVariable('Path', 'User'))
      )
    }
    @($persistedPaths | ForEach-Object { $_ -split ';' }) + @($env:PATH -split ';')
  } else {
    @($env:PATH -split [IO.Path]::PathSeparator)
  }

  foreach ($entry in $candidatePaths) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    # Persisted PATH entries can carry %VARIABLE% references, which Test-Path
    # would otherwise treat as literal directory names.
    $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry)
    foreach ($fileName in @('bun.exe', 'bun.cmd', 'bun')) {
      $candidate = Join-Path -Path $expandedEntry -ChildPath $fileName
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }

  return $null
}

<#
.SYNOPSIS
  Prepends or appends a directory to the current session PATH, deduplicating.
.DESCRIPTION
  Adds the specified directory to $env:PATH if it is not already present, at
  the specified position (Prepend or Append).  Uses -notlike wildcard matching
  to avoid duplicate entries.
.PARAMETER Path
  The directory path to add.  Must be a full absolute path.
.PARAMETER Position
  Whether to Prepend (default) or Append the entry.
.EXAMPLE
  Add-NucleusPathEntry -Path "C:\Tools\bin" -> prepends to PATH
  Add-NucleusPathEntry -Path "C:\Tools\bin" -Position Append -> appends
#>
function Add-NucleusPathEntry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter()]
    [ValidateSet('Prepend', 'Append')]
    [string]$Position = 'Append'
  )
  if ($Position -eq 'Prepend') {
    if ($env:PATH -notlike "*$Path*") {
      $env:PATH = "$Path;$env:PATH"
    }
  } else {
    if ($env:PATH -notlike "*$Path*") {
      $env:PATH = "$env:PATH;$Path"
    }
  }
}
