function Invoke-UvSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative uv tool set (install + prune).

  .DESCRIPTION
    Maintains a managed set of Python CLI tools installed via `uv tool install`.
    On each apply it queries `uv tool list` for the actually installed set,
    removes anything installed but absent from the desired list (zap-style),
    and installs any desired tools that are missing.

    Mirrors the installUvTools POSIX activation in agents.nix.

    Requires uv to be on PATH (installed from WinGet by system.dsc.yml).
    Prepends %USERPROFILE%\.local\bin to PATH internally so uv-installed
    binaries are accessible in subsequent steps of the same apply session.

  .EXAMPLE
    Invoke-UvSetup

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact PyPI
  # package name (without extras).  Only add packages absent from WinGet,
  # Scoop, and cargo-binstall.
  $desiredPackages = @(
    # PaddleOCR: cross-platform OCR with GPU auto-detection.
    # Managed via uv for version consistency across all hosts.
    'paddleocr'
    # LiteLLM AI gateway proxy.  Installed with the [proxy] extra for
    # OpenAI-compatible server functionality.  The tool name in `uv tool list`
    # is `litellm` (extras are stripped from the tool registry).
    'litellm'
  )

  # Packages that need extras syntax during install (e.g. 'litellm[proxy]').
  # Keyed by tool name (as it appears in uv tool list).
  $packageExtras = @{
    'litellm' = '[proxy]'
  }

  # uv tool install places binaries in ~\.local\bin by default (UV_TOOL_BIN_DIR).
  $uvBinDir = Join-Path $HOME ".local\bin"

  # Per-tool Python version requirements.  Empty/null = use default.
  $toolPythonVersion = @{
    'paddleocr' = '3.11'
  }

  # Guard: uv must be accessible after WinGet DSC has installed astral-sh.uv.
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    # -ErrorAction SilentlyContinue is intentional: absence of uv is an
    # expected probe condition; the if-guard checks the result immediately.
    Write-Error "Invoke-UvSetup: uv not found on PATH; ensure astral-sh.uv was installed by WinGet DSC before calling this function"
    return
  }

  # Ensure required Python versions are available before installing tools.
  $pythonVersions = $toolPythonVersion.Values | Where-Object { $_ } | Sort-Object -Unique
  foreach ($ver in $pythonVersions) {
    uv python install $ver
  }

  # Prepend ~/.local/bin so binaries installed during this apply run are
  # accessible in subsequent steps without opening a new terminal session.
  if ($env:PATH -notlike "*$uvBinDir*") {
    $env:PATH = "$uvBinDir;$env:PATH"
  }

  # Get actually installed uv tools from `uv tool list` (zap-style: remove
  # any installed tool absent from the desired list, regardless of prior
  # managed state). Parse only "name vX.Y.Z" lines so separators/headers
  # cannot become uninstall candidates.
  $uvListOutput = @(uv tool list 2>&1 | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*\s+v\d' })
  $installedTools = @($uvListOutput | ForEach-Object { ($_ -split '\s+')[0] })

  # Tools installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedTools | Where-Object { $desiredPackages -notcontains $_ })

  # Desired tools not yet installed.  uv tool install uses the package name
  # as the binary name by default; fall back to binary-presence check.
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $installedTools -notcontains $pkg
  })

  # Prune packages removed from the desired list.
  foreach ($pkg in $toRemove) {
    if ($pkg -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
      Write-Output "uv: skipping invalid uninstall token '$pkg'"
      continue
    }
    Write-Output "uv: uninstalling removed tool '$pkg'"
    uv tool uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "uv: 'uv tool uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "uv: '$pkg' uninstalled"
  }

  # Install additions.
  foreach ($pkg in $toInstall) {
    if ($pkg -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
      Write-Output "uv: skipping invalid install token '$pkg'"
      continue
    }
    $installSpec = if ($packageExtras.ContainsKey($pkg)) { "$pkg$($packageExtras[$pkg])" } else { $pkg }
    $pythonVersion = if ($toolPythonVersion.ContainsKey($pkg)) { $toolPythonVersion[$pkg] } else { $null }
    $pythonArg = if ($pythonVersion) { @('--python', $pythonVersion) } else { @() }
    if ($pythonVersion) {
      Write-Output "uv: installing tool '$installSpec' with Python $pythonVersion"
    } else {
      Write-Output "uv: installing tool '$installSpec'"
    }
    uv tool install @pythonArg $installSpec
    if ($LASTEXITCODE -ne 0) {
      Write-Error "uv: 'uv tool install $installSpec' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "uv: '$installSpec' installed successfully"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "uv: all managed tools already converged — skipping"
  }

}
