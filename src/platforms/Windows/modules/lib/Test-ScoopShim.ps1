<#
.SYNOPSIS
    Test that a Scoop package produced at least one command on the managed shim PATH.
.DESCRIPTION
    Scoop creates a shim per entry in the manifest's `bin` list, and a manifest
    is free to name executables that differ from the package name: the
    whisper-cpp manifest declares whisper-cli.exe, whisper-stream.exe and six
    others, none of which is whisper-cpp.exe. Guessing a single shim name from
    the package name therefore reports a healthy install as broken, and because
    the caller's failure path returns from the whole step, that also skips every
    remaining install and the `scoop hold` sweep.

    So the name guess is only the fast path. When it misses, this falls back to
    the authoritative record: each shim's sibling `.shim` file records the app
    path it was created for, so a shim belongs to the package when its `.shim`
    file names that package's app directory.
.PARAMETER PackageName
    Scoop app name exactly as it appears in the desired package registry.
.OUTPUTS
    [bool] True when at least one shim resolves to the package.
.EXAMPLE
    Test-ScoopShim -PackageName 'qemu'

    qemu's manifest declares qemu.exe, so the fast path matches and no shim file
    is read.
.EXAMPLE
    Test-ScoopShim -PackageName 'whisper-cpp'

    Returns True through the .shim fallback, because the manifest declares
    whisper-cli.exe and friends rather than whisper-cpp.exe.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
#>
function Test-ScoopShim {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$PackageName
  )

  $shimsDir = Get-NucleusScoopShimsDir
  if ((Test-Path -Path (Join-Path -Path $shimsDir -ChildPath "$PackageName.cmd")) -or
      (Test-Path -Path (Join-Path -Path $shimsDir -ChildPath "$PackageName.exe"))) {
    return $true
  }

  # Scoop writes `..\apps\<name>\<version>\...` into every .shim file, so the
  # app directory is the package identity a shim belongs to. Escape the name:
  # it comes from the registry, and a regex metacharacter in it would silently
  # widen the match onto other packages.
  $appDirPattern = 'apps\\' + [regex]::Escape($PackageName) + '\\'
  # check-suppress:suppression_doc: probe -- a missing shims directory means no shim was created, which is the answer the caller asked for
  $shimFiles = @(Get-ChildItem -Path $shimsDir -Filter '*.shim' -File -ErrorAction SilentlyContinue)
  foreach ($shimFile in $shimFiles) {
    # check-suppress:suppression_doc: probe -- an unreadable shim file cannot name the package, so the package is reported as unshimmed
    $content = Get-Content -LiteralPath $shimFile.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match $appDirPattern) {
      return $true
    }
  }
  return $false
}
