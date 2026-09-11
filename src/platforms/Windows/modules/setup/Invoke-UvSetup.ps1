function Invoke-UvSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative uv tool set (install + prune).

  .DESCRIPTION
    Maintains a managed set of Python CLI tools installed via `uv tool install`.
    On each apply it queries `uv tool list` for the actually installed set,
    removes anything installed but absent from the desired list (zap-style),
    and installs any desired tools that are missing.

    Mirrors the install-uv-tools POSIX activation in agents.nix.

    The desired set and the per-tool rationale live in the shared registry
    src/modules/packages/desired.json (uv -> <host>).  An entry may pin its
    version to a flake.lock node ("pin": "flake:<node>") when the declarative
    POSIX provisioning, not a PyPI release, is the authoritative version.

    Requires uv to be on PATH (installed from WinGet by system/packages.dsc.yml).
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

  # Derive repo root from script location (src/platforms/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"
  $flakeLockPath = Join-Path $repoRoot "src\flake.lock"

  # Get-NucleusHostKey resolves the canonical host key used to slice the shared
  # desired-package registry.
  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1")

  # Resolve-NucleusFlakePin turns a "flake:<node>" pin into a GitHub source and
  # revision; the enforcement lib uses the same helper for its rev probe.
  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\lib\Resolve-NucleusFlakePin.ps1")

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $uvVersions = if ($lockfile -and $lockfile.uv) { $lockfile.uv } else { @{} }

  # Declarative desired-state list from the shared registry (single source of
  # truth: src/modules/packages/desired.json).  Entries are objects with named
  # fields; python/extras are read into per-tool lookup tables so one tool's
  # version can never land in another tool's slot.
  $desiredPath = Join-Path $repoRoot "src\modules\packages\desired.json"
  if (-not (Test-Path -LiteralPath $desiredPath)) {
    Write-NucleusError -CommandName 'Invoke-UvSetup' "desired package registry not found at '$desiredPath'"
    return
  }
  $hostKey = Get-NucleusHostKey
  $hostDesired = (Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json).uv.$hostKey
  if ($null -eq $hostDesired) {
    Write-NucleusError -CommandName 'Invoke-UvSetup' "desired package registry has no uv list for host '$hostKey'"
    return
  }
  $desiredPackages = @($hostDesired | ForEach-Object { $_.name })

  # Packages that need extras syntax during install (e.g. 'litellm[proxy]').
  # Keyed by tool name (as it appears in uv tool list).
  $packageExtras = @{}

  # Per-tool Python version requirements.  Absent = use the uv default.
  $toolPythonVersion = @{}

  # Tools pinned to a flake.lock rev ("flake:<node>"), keyed by tool name.  Such
  # a tool must match the rev the declarative POSIX provisioning uses, which no
  # PyPI release tracks.
  $uvPins = @{}
  foreach ($entry in $hostDesired) {
    if ($entry.extras) {
      $packageExtras[$entry.name] = "[$($entry.extras)]"
    }
    if ($entry.python) {
      $toolPythonVersion[$entry.name] = $entry.python
    }
    if (-not $entry.pin) { continue }
    if ($entry.pin -notmatch '^flake:(.+)$') {
      Write-NucleusError -CommandName 'Invoke-UvSetup' "unsupported pin '$($entry.pin)' for tool '$($entry.name)'; expected 'flake:<node>'"
      return
    }
    $nodeName = $Matches[1]
    $resolvedPin = Resolve-NucleusFlakePin -Node $nodeName -FlakeLockPath $flakeLockPath
    if (-not $resolvedPin.Ok) {
      switch ($resolvedPin.Reason) {
        'missing-lockfile' {
          Write-NucleusError -CommandName 'Invoke-UvSetup' "tool '$($entry.name)' is pinned to flake node '$nodeName' but '$flakeLockPath' is missing"
        }
        'missing-node' {
          Write-NucleusError -CommandName 'Invoke-UvSetup' "flake.lock has no locked rev for node '$nodeName' (pinned by tool '$($entry.name)')"
        }
        default {
          Write-NucleusError -CommandName 'Invoke-UvSetup' "flake node '$nodeName' is not a github input; cannot derive an install source for tool '$($entry.name)'"
        }
      }
      return
    }
    $uvPins[$entry.name] = [pscustomobject]@{
      source = $resolvedPin.Source
      rev    = $resolvedPin.Rev
    }
  }

  # uv tool install places binaries in ~\.local\bin by default (UV_TOOL_BIN_DIR).
  # Canonical source: ManagedPaths.ps1 -> managed-paths.nix (pathComponents).
  $uvBinDir = Get-NucleusManagedBinDir "local"

  # Guard: uv must be accessible after WinGet DSC has installed astral-sh.uv.
  # check-suppress:suppression_doc: probe -- uv may not be installed; if-guard checks absence below.
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-NucleusError -CommandName 'Invoke-UvSetup' "uv not found on PATH; ensure astral-sh.uv was installed by WinGet DSC before calling this function"
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
    $env:PATH = "$env:PATH;$uvBinDir"
  }

  # Get actually installed uv tools from `uv tool list` (zap-style: remove
  # any installed tool absent from the desired list, regardless of prior
  # managed state). Parse only "name vX.Y.Z" lines so separators/headers
  # cannot become uninstall candidates.
  $uvListOutput = @(uv tool list 2>&1 | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*\s+v\d' })
  $installedVersions = @{}
  $installedTools = @($uvListOutput | ForEach-Object {
    $parts = $_ -split '\s+'
    $version = $parts[1]
    if ($version) { $installedVersions[$parts[0]] = $version -replace '^v', '' }
    $parts[0]
  })

  # Tools installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedTools | Where-Object { $desiredPackages -notcontains $_ })

  # Desired tools not yet installed OR installed at a version different from
  # the lockfile pin (version-aware reconciliation).
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $isInstalled = $installedTools -contains $pkg
    if (-not $isInstalled) { return $true }
    $entry = if ($uvPins.ContainsKey($pkg)) { $uvPins[$pkg] } else { $uvVersions.$pkg }
    if ($entry -is [string]) {
      # Version-pinned entry: reinstall if version mismatch.
      if (-not $entry) { return $false }
      $installedVersion = $installedVersions[$pkg]
      return $installedVersion -ne $entry
    }
    # Hash-pinned entry (PSObject with .source/.rev): already installed, skip.
    return $false
  })

  # Prune packages removed from the desired list.
  foreach ($pkg in $toRemove) {
    if ($pkg -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
      Write-NucleusInfo -CommandName 'uv' "skipping invalid uninstall token '$pkg'"
      continue
    }
    Write-NucleusInfo -CommandName 'uv' "uninstalling removed tool '$pkg'"
    uv tool uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'uv' "'uv tool uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'uv' "'$pkg' uninstalled"
  }

  # Install additions (fresh installs and version-mismatch reinstalls).
  foreach ($pkg in $toInstall) {
    $entry = if ($uvPins.ContainsKey($pkg)) { $uvPins[$pkg] } else { $uvVersions.$pkg }
    if ($entry -is [string]) {
      # Version-pinned entry: install from PyPI.
      $version = $entry
      $pkgWithVersion = if ($version) { "${pkg}==${version}" } else { $pkg }
      $installSpec = if ($packageExtras.ContainsKey($pkg)) { "$pkgWithVersion$($packageExtras[$pkg])" } else { $pkgWithVersion }
      $pythonVersion = if ($toolPythonVersion.ContainsKey($pkg)) { $toolPythonVersion[$pkg] } else { $null }
      $pythonArg = if ($pythonVersion) { @('--python', $pythonVersion) } else { @() }
      $reinstallArg = if ($installedTools -contains $pkg) { @('--reinstall') } else { @() }
      if ($pythonVersion) {
        Write-NucleusInfo -CommandName 'uv' "installing tool '$installSpec' with Python $pythonVersion"
      } else {
        Write-NucleusInfo -CommandName 'uv' "installing tool '$installSpec'"
      }
      uv tool install @pythonArg $reinstallArg $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'uv' "'uv tool install $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
      Write-NucleusInfo -CommandName 'uv' "'$installSpec' installed successfully"
    } else {
      # Hash-pinned entry: install from VCS.
      $source = $entry.source
      $rev = $entry.rev
      $installSpec = "${pkg} @ git+$source@$rev"
      $pythonVersion = if ($toolPythonVersion.ContainsKey($pkg)) { $toolPythonVersion[$pkg] } else { $null }
      $pythonArg = if ($pythonVersion) { @('--python', $pythonVersion) } else { @() }
      $reinstallArg = if ($installedTools -contains $pkg) { @('--reinstall') } else { @() }
      if ($pythonVersion) {
        Write-NucleusInfo -CommandName 'uv' "installing tool '$installSpec' with Python $pythonVersion"
      } else {
        Write-NucleusInfo -CommandName 'uv' "installing tool '$installSpec'"
      }
      uv tool install @pythonArg $reinstallArg $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'uv' "'uv tool install $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
      Write-NucleusInfo -CommandName 'uv' "'$installSpec' installed successfully"
    }
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-NucleusInfo -CommandName 'uv' "all managed tools already converged — skipping"
  }

}
