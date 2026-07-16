<#
.SYNOPSIS
  Canonical Windows-side declaration of managed PATH directories.

.DESCRIPTION
  Mirrors pathComponents in src/modules/lib/managed-paths.nix — that file is the
  authoritative cross-platform source; this module is the Windows-side
  consumer equivalent.  Every PowerShell script that needs to prepend managed
  bin directories should reference the variables or function here rather than
  hardcoding the path strings.

  Variables are scoped script: to prevent leaks when dot-sourced.

  $script:nucleusPathComponents — hash table with Prepend/Append arrays (relative)
  $script:nucleusPrependRegistry — registry-format paths (%USERPROFILE%-prefixed)
  Get-NucleusManagedBinDir         — resolves a single bin dir by component name
#>

# Canonical source: src/modules/lib/managed-paths.nix (pathComponents)
$script:nucleusPathComponents = @{
  Prepend = @(
    '.bun\bin'
    '.cargo\bin'
    '.local\bin'
  )
  Append  = @()  # reserved; mirrors pathComponents.append (currently empty)
}

# Registry-format %USERPROFILE%-prefixed paths (REG_EXPAND_SZ) for HKLM Path.
# Used by Sync-UserPath.ps1.
# Elements already include \bin suffix, so just prefix with %USERPROFILE%.
$script:nucleusPrependRegistry = $script:nucleusPathComponents.Prepend | ForEach-Object {
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
  param()
  "C:\Program Files\LLVM\bin"
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
    [string]$Position = 'Prepend'
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
