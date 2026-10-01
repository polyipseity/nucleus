# Test-ScoopShim is a shared predicate in lib/; apply.ps1 already loaded its
# dependency Get-NucleusScoopShimsDir.
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Test-ScoopShim.ps1')

function Invoke-ScoopSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative Scoop app set (install + prune).

  .DESCRIPTION
    Register the 'extras' and 'main' buckets, then reconcile the apps directory
    against the desired list, removing what is not declared and installing what
    is missing at the lockfile version.

    Runs after the WinGet DSC step that installs Scoop.Scoop, because the shims
    directory is not on PATH in the parent session until prepended.

    The desired set and per-app rationale live in
    src/modules/packages/desired.json (scoop -> <host>). Custom bucket
    manifests live in src/modules/scoop-manifests/.

  .EXAMPLE
    Invoke-ScoopSetup
  #>
  [CmdletBinding()]
  param()

  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1")

  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $scoopVersions = if ($lockfile -and $lockfile.scoop) { $lockfile.scoop } else { @{} }

  # Only packages absent from WinGet are managed here.
  $desiredPath = Join-Path $repoRoot "src\modules\packages\desired.json"
  if (-not (Test-Path -LiteralPath $desiredPath)) {
    Write-NucleusError -CommandName 'Invoke-ScoopSetup' "desired package registry not found at '$desiredPath'"
    return
  }
  $hostKey = Get-NucleusHostKey
  $hostDesired = (Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json).scoop.$hostKey
  if ($null -eq $hostDesired) {
    Write-NucleusError -CommandName 'Invoke-ScoopSetup' "desired package registry has no scoop list for host '$hostKey'"
    return
  }
  $desiredPackages = @($hostDesired | ForEach-Object {
    @{ name = $_.name; bucket = $_.bucket }
  })
  $desiredNames = @($desiredPackages | ForEach-Object { $_.name })

  # DSC runs in a child process, so its PATH additions never reach this
  # session; the shims path has to be added here.
  Add-NucleusPathEntry -Path (Get-NucleusScoopShimsDir)

  if (-not (Test-Path (Join-Path (Get-NucleusScoopShimsDir) "scoop.cmd"))) {
    Write-NucleusError -CommandName 'Invoke-ScoopSetup' "scoop not found at '$(Get-NucleusScoopShimsDir)\scoop.cmd'; ensure Scoop.Scoop was installed by WinGet DSC before calling this function"
    return
  }

  # 'main' is the default bucket but can be absent on a fresh install;
  # 'extras' hosts qemu.
  foreach ($bucket in @('extras', 'main')) {
    # 'scoop bucket list' exits non-zero when nothing is registered yet, and
    # the -notmatch guard below is the real check.
    $existing = scoop bucket list 2>&1
    if ($existing -notmatch "(?m)^$bucket\b") {
      Write-NucleusInfo -CommandName 'scoop' "adding bucket '$bucket'"
      scoop bucket add $bucket
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'scoop' "failed to add bucket '$bucket' (exit $LASTEXITCODE)"
        return
      }
    }
  }

  # Copy repo-owned manifests into ~/.scoop/buckets/nucleus/ so Scoop can
  # resolve nucleus/<package> installs.
  $manifestsSource = Join-Path $repoRoot "src\modules\scoop-manifests"
  if (Test-Path -LiteralPath $manifestsSource) {
    $manifestFiles = @(Get-ChildItem -Path $manifestsSource -Filter '*.json' -File)
    if ($manifestFiles.Count -gt 0) {
      $nucleusBucketDir = Join-Path $env:USERPROFILE "scoop\buckets\nucleus"
      if (-not (Test-Path -LiteralPath $nucleusBucketDir)) {
        New-Item -Path $nucleusBucketDir -ItemType Directory -Force > $null
      }
      foreach ($mf in $manifestFiles) {
        $dest = Join-Path $nucleusBucketDir $mf.Name
        Copy-Item -Path $mf.FullName -Destination $dest -Force
      }
      Write-NucleusInfo -CommandName 'scoop' "provisioned nucleus custom bucket with $($manifestFiles.Count) manifest(s)"
    }
  }

  # ~\scoop\apps\<name>\ directory names are the authoritative installed set.
  $scoopAppsDir = Join-Path $env:USERPROFILE "scoop\apps"
  $installedApps = @()
  if (Test-Path $scoopAppsDir) {
    $installedApps = @(
      Get-ChildItem -Path $scoopAppsDir -Directory |
        Select-Object -ExpandProperty Name
    )
  }

  $installedVersions = @{}
  $scoopListOutput = @(scoop list 2>&1)
  $scoopListOutput | Select-String "^'(.+)' \((\S+)\)" | ForEach-Object {
    $installedVersions[$_.Matches.Groups[1].Value] = $_.Matches.Groups[2].Value
  }

  # Removing an app absent from the declared set, however it got installed.
  $toRemove = @($installedApps | Where-Object { $desiredNames -notcontains $_ })

  # Missing, or installed at a version other than the lockfile pin.
  $toInstall = @($desiredPackages | Where-Object {
    $pkgName = $_.name
    $isInstalled = $installedApps -contains $pkgName
    if (-not $isInstalled) { return $true }
    $expectedVersion = $scoopVersions.$pkgName
    if (-not $expectedVersion) { return $false }
    $installedVersion = $installedVersions[$pkgName]
    $installedVersion -ne $expectedVersion
  })

  foreach ($pkg in $toRemove) {
    Write-NucleusInfo -CommandName 'scoop' "uninstalling removed package '$pkg'"
    scoop uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'scoop' "'scoop uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'scoop' "'$pkg' uninstalled"
  }

  foreach ($entry in $toInstall) {
    $pkgName = $entry.name
    $pkgBucket = $entry.bucket
    $version = $scoopVersions.$pkgName
    $installSpec = if ($pkgBucket) {
      if ($version) { "$pkgBucket/$pkgName@$version" } else { "$pkgBucket/$pkgName" }
    } else {
      if ($version) { "$pkgName@$version" } else { $pkgName }
    }
    Write-NucleusInfo -CommandName 'scoop' "installing '$installSpec'"
    scoop install $installSpec
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'scoop' "'scoop install $installSpec' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-ScoopShim -PackageName $pkgName)) {
      Write-NucleusError -CommandName 'scoop' "'$pkgName' installed but no shim found under '$(Get-NucleusScoopShimsDir)'"
      return
    }
    Write-NucleusInfo -CommandName 'scoop' "'$pkgName' installed successfully"
  }

  # Hold every managed package at its locked version.
  foreach ($pkgName in $desiredNames) {
    scoop hold $pkgName 2>&1 > $null
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-NucleusInfo -CommandName 'scoop' "all managed packages already converged — skipping"
  }

}
