<#
.SYNOPSIS
  Android VM ADB/fastboot helpers for Windows nucleus-vm android-config.

.DESCRIPTION
  PowerShell port of vm_android_* helpers from src/scripts/lib/vm.sh (Android
  guest configuration section). Dot-sourced by Invoke-AndroidConfig.ps1 and
  scripts/vm.ps1; not invoked directly.

.NOTES
  Requires Format-NucleusOutput (Write-NucleusInfo / Write-NucleusError /
  Write-NucleusWarning) in the caller scope.
#>

function Assert-AndroidTool {
  <#
  .SYNOPSIS
    Fail fast when a required host tool is missing from PATH.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  # check-suppress:suppression_doc: probe whether the host tool is on PATH; absence takes the error branch below.
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    Write-NucleusError "$Name is required but was not found in PATH"
    exit 1
  }
}

function Invoke-AndroidExternalWithTimeout {
  <#
  .SYNOPSIS
    Run an external command with a wall-clock timeout (mirrors run_command_with_timeout).
  #>
  param(
    [Parameter(Mandatory)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory)]
    [string]$FilePath,
    [Parameter()]
    [string[]]$ArgumentList = @(),
    [ref]$StdOut = $null,
    [ref]$StdErr = $null
  )

  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
      -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
      if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        $process.Kill($true)
        return 124
      }
      Start-Sleep -Milliseconds 200
    }
    # check-suppress:suppression_doc: read captured output best-effort; empty file means the process produced no output.
    if ($null -ne $StdOut) { $StdOut.Value = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue) }
    # check-suppress:suppression_doc: read captured output best-effort; empty file means the process produced no output.
    if ($null -ne $StdErr) { $StdErr.Value = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue) }
    return $process.ExitCode
  }
  finally {
    # check-suppress:suppression_doc: temp files may already be gone after process exit; removal is best-effort cleanup.
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-AndroidWithBackoff {
  <#
  .SYNOPSIS
    Retry a script block with exponential backoff (mirrors run_with_backoff).
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Label,
    [Parameter(Mandatory)]
    [scriptblock]$Action,
    [int]$MaxAttempts = 1
  )

  $attempt = 1
  while ($attempt -le $MaxAttempts) {
    if (& $Action) {
      return $true
    }
    if ($attempt -ge $MaxAttempts) {
      return $false
    }
    $sleepSeconds = [Math]::Min(30, [Math]::Pow(2, $attempt - 1))
    Write-NucleusWarning "$Label failed (attempt $attempt/$MaxAttempts); retrying in ${sleepSeconds}s"
    Start-Sleep -Seconds $sleepSeconds
    $attempt++
  }
  return $false
}

function Get-AndroidVmRecord {
  param(
    [Parameter(Mandatory)]
    [object]$Manifest,
    [Parameter(Mandatory)]
    [int]$VmIndex
  )
  return $Manifest.VMs[$VmIndex]
}

function Get-AndroidVmArch {
  param(
    [Parameter(Mandatory)]
    [string]$VmType
  )

  switch ($VmType) {
    'Android' { return 'aarch64' }
    'Windows' { return 'x86_64' }
    default {
      if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64|ARM') { return 'aarch64' }
      return 'x86_64'
    }
  }
}

function Get-AndroidAdbHostPort {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $forward = @($Vm.portForwards | Where-Object { $_.guestPort -eq 5555 }) | Select-Object -First 1
  if ($null -eq $forward) {
    Write-NucleusError 'no ADB port forward (guestPort 5555) in manifest'
    exit 1
  }
  return [string]$forward.hostPort
}

function Get-AndroidFastbootHostPort {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $forward = @($Vm.portForwards | Where-Object { $_.guestPort -eq 5554 }) | Select-Object -First 1
  if ($null -eq $forward) {
    Write-NucleusError 'no fastboot port forward (guestPort 5554) in manifest'
    exit 1
  }
  return [string]$forward.hostPort
}

function Get-AndroidAdbSerial {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )
  return "localhost:$(Get-AndroidAdbHostPort -Vm $Vm)"
}

function Get-AndroidFastbootSerial {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )
  return "tcp:localhost:$(Get-AndroidFastbootHostPort -Vm $Vm)"
}

function Test-AndroidFastbootProbe {
  param(
    [Parameter(Mandatory)]
    [string]$Serial,
    [Parameter(Mandatory)]
    [string]$GetVarName
  )

  $stderr = $null
  $stdout = $null
  $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds 8 -FilePath 'fastboot' `
    -ArgumentList @('-s', $Serial, 'getvar', $GetVarName) -StdOut ([ref]$stdout) -StdErr ([ref]$stderr)
  if ($exitCode -ne 0) { return $false }
  $combined = if ($stdout) { $stdout } else { '' }
  if ($stderr) { $combined += $stderr }
  return ($combined -match "(?m)^$([regex]::Escape($GetVarName)):")
}

function Get-AndroidFastbootListState {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $serial = Get-AndroidFastbootSerial -Vm $Vm
  if ((Test-AndroidFastbootProbe -Serial $serial -GetVarName 'is-userspace') `
      -or (Test-AndroidFastbootProbe -Serial $serial -GetVarName 'version')) {
    return 'fastboot'
  }
  return 'offline'
}

function Wait-AndroidFastboot {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 180
  )

  $serial = Get-AndroidFastbootSerial -Vm $Vm
  if ((Get-AndroidFastbootListState -Vm $Vm) -eq 'fastboot') {
    Write-NucleusInfo "guest already in fastboot on $serial"
    return $true
  }

  Write-NucleusInfo "waiting for fastboot on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  $lastHint = -30
  while ($elapsed -lt $TimeoutSeconds) {
    if ((Get-AndroidFastbootListState -Vm $Vm) -eq 'fastboot') {
      return $true
    }
    if ($elapsed -ge ($lastHint + 30)) {
      Write-NucleusInfo 'manual step: in LineageOS Recovery, open Advanced → Enter fastboot'
      $lastHint = $elapsed
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
  }

  Write-NucleusError "timed out waiting for fastboot on $serial; enter fastboot from recovery and retry"
  return $false
}

function Get-AndroidAdbGetState {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  # check-suppress:suppression_doc: get-state may fail while guest is booting; offline is the expected fallback.
  $state = & adb -s $serial get-state 2>$null
  if ($state) { return ($state | Out-String).Trim() }
  return 'unknown'
}

function Invoke-AndroidAdbRefresh {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  # check-suppress:suppression_doc: disconnect clears stale unauthorized/recovery entries on network ADB.
  & adb disconnect $serial 1>$null 2>$null
  # check-suppress:suppression_doc: connect is idempotent; failure while the guest is still booting is expected.
  & adb connect $serial 1>$null 2>$null
}

function Get-AndroidAdbListState {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $devicesOutput = & adb devices 2>$null  # check-suppress:suppression_doc: adb devices may fail when the daemon cannot start; empty list handled below.
  foreach ($line in @($devicesOutput)) {
    $trimmed = ($line | Out-String).Trim()
    if ($trimmed -match "^$([regex]::Escape($serial))\s+(\S+)") {
      return $Matches[1]
    }
  }

  $getState = Get-AndroidAdbGetState -Vm $Vm
  if ($getState -and $getState -ne 'unknown') {
    return $getState
  }
  return 'offline'
}

function Get-AndroidAdbPollState {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  Invoke-AndroidAdbRefresh -Vm $Vm
  return (Get-AndroidAdbListState -Vm $Vm)
}

function Wait-AndroidAdbAuthorized {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 600
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "waiting for authorized ADB on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  $lastUnauthMsg = -30

  while ($elapsed -lt $TimeoutSeconds) {
    $state = Get-AndroidAdbPollState -Vm $Vm
    switch ($state) {
      'device' { return $true }
      'unauthorized' {
        if ($elapsed -ge ($lastUnauthMsg + 30)) {
          Write-NucleusInfo 'ADB unauthorized — boot LineageOS, enable USB debugging, and tap Allow on the device'
          $lastUnauthMsg = $elapsed
        }
      }
      { $_ -in @('recovery', 'sideload') } {
        if ($elapsed -ge ($lastUnauthMsg + 30)) {
          Write-NucleusInfo "guest is in $state; boot LineageOS system for this step (Reboot system now from recovery)"
          $lastUnauthMsg = $elapsed
        }
      }
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
  }

  $final = Get-AndroidAdbPollState -Vm $Vm
  if ($final -eq 'unauthorized') {
    Write-NucleusError "timed out waiting for ADB authorization on $serial; boot LineageOS and tap Allow USB debugging"
  }
  else {
    Write-NucleusError "timed out waiting for authorized ADB on $serial"
  }
  return $false
}

function Test-AndroidGuestBootCompleted {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  if ((Get-AndroidAdbPollState -Vm $Vm) -ne 'device') {
    return $false
  }
  return ((Get-AndroidShellGetprop -Vm $Vm -Name 'sys.boot_completed') -eq '1')
}

function Wait-AndroidAdbBootCompleted {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 600
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "waiting for booted guest on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  $lastHint = -30

  while ($elapsed -lt $TimeoutSeconds) {
    $state = Get-AndroidAdbPollState -Vm $Vm
    switch ($state) {
      'device' {
        if (Test-AndroidGuestBootCompleted -Vm $Vm) {
          return $true
        }
        if ($elapsed -ge ($lastHint + 30)) {
          Write-NucleusInfo 'guest ADB is up but still booting (waiting for sys.boot_completed=1)...'
          $lastHint = $elapsed
        }
      }
      'unauthorized' {
        if ($elapsed -ge ($lastHint + 30)) {
          Write-NucleusInfo 'ADB unauthorized — boot LineageOS, enable USB debugging, and tap Allow on the device'
          $lastHint = $elapsed
        }
      }
      { $_ -in @('recovery', 'sideload') } {
        if ($elapsed -ge ($lastHint + 30)) {
          Write-NucleusInfo "guest is in $state; boot LineageOS system for this step (Reboot system now from recovery)"
          $lastHint = $elapsed
        }
      }
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
  }

  $final = Get-AndroidAdbPollState -Vm $Vm
  if ($final -eq 'unauthorized') {
    Write-NucleusError "timed out waiting for booted guest on $serial; tap Allow USB debugging"
  }
  elseif ($final -eq 'device') {
    Write-NucleusError "timed out waiting for boot completion on $serial (sys.boot_completed never became 1)"
  }
  else {
    Write-NucleusError "timed out waiting for booted guest on $serial (state: $final)"
  }
  return $false
}

function Wait-AndroidAdbSideload {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 120
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "waiting for sideload ADB on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  $lastHint = -15

  while ($elapsed -lt $TimeoutSeconds) {
    $state = Get-AndroidAdbPollState -Vm $Vm
    switch ($state) {
      'sideload' { return $true }
      'recovery' {
        if ($elapsed -ge ($lastHint + 15)) {
          Write-NucleusInfo 'manual step: in recovery, select Apply update from ADB to enter sideload mode'
          $lastHint = $elapsed
        }
      }
      'unauthorized' {
        if ($elapsed -ge ($lastHint + 15)) {
          Write-NucleusInfo 'ADB unauthorized — enable ADB in recovery (Advanced → Enable ADB)'
          $lastHint = $elapsed
        }
      }
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
  }

  $final = Get-AndroidAdbPollState -Vm $Vm
  Write-NucleusError "timed out waiting for sideload ADB on $serial (state: $final)"
  return $false
}

function Connect-AndroidAdb {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 150
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "waiting for ADB on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  while ($elapsed -lt $TimeoutSeconds) {
    $state = Get-AndroidAdbPollState -Vm $Vm
    if ($state -in @('device', 'recovery', 'sideload')) {
      return $true
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
  }
  return $false
}

function Get-AndroidShellGetprop {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [Parameter(Mandatory)]
    [string]$Name
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $value = & adb -s $serial shell getprop $Name 2>$null  # check-suppress:suppression_doc: getprop may fail while guest is booting; empty value handled below.
  if (-not $value) { return '' }
  return (($value | Out-String) -replace "`r`n", '').Trim()
}

function Test-AndroidGuestShellIsRoot {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $uid = & adb -s $serial shell 'id -u' 2>$null  # check-suppress:suppression_doc: id -u may fail while guest is booting; empty output handled below.
  return ((($uid | Out-String) -replace "`r", '').Trim() -eq '0')
}

function Get-AndroidRecoveryAssetSuffix {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $arch = Get-AndroidVmArch -VmType ([string]$Vm.type)
  if ($arch -eq 'aarch64') { return 'arm64only' }
  return 'x86_64'
}

function Get-AndroidJqssunReleaseTagForAsset {
  param(
    [Parameter(Mandatory)]
    [string]$AssetName
  )

  if ([string]::IsNullOrWhiteSpace($AssetName)) {
    Write-NucleusError 'jqssun asset name is required'
    return $null
  }

  $url = "https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$AssetName"
  $location = $null
  try {
    $response = Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 0 -ErrorAction Stop
    $location = $response.Headers['Location']
  }
  catch {
    $response = $_.Exception.Response
    if ($null -ne $response) {
      $location = $response.Headers['Location']
    }
    if ([string]::IsNullOrWhiteSpace($location)) {
      Write-NucleusError "failed to resolve jqssun release redirect for $AssetName"
      return $null
    }
  }

  if ([string]::IsNullOrWhiteSpace($location)) {
    $location = $response.Headers['Location']
  }
  if ([string]::IsNullOrWhiteSpace($location)) {
    Write-NucleusError "failed to resolve jqssun release redirect for $AssetName (no Location header)"
    return $null
  }

  if ($location -match '/releases/download/([^/]+)/') {
    return $Matches[1]
  }

  Write-NucleusError "failed to parse jqssun release tag from redirect for $AssetName"
  return $null
}

function Get-AndroidJqssunAssetUrl {
  param(
    [Parameter(Mandatory)]
    [string]$Tag,
    [Parameter(Mandatory)]
    [string]$AssetSubstring
  )

  if ([string]::IsNullOrWhiteSpace($Tag) -or [string]::IsNullOrWhiteSpace($AssetSubstring)) {
    Write-NucleusError 'jqssun release tag and asset substring are required'
    return $null
  }

  $pageUrl = "https://github.com/jqssun/android-lineage-qemu/releases/expanded_assets/$Tag"
  try {
    $page = (Invoke-WebRequest -Uri $pageUrl -UseBasicParsing).Content
  }
  catch {
    Write-NucleusError "failed to fetch jqssun release asset list for $Tag"
    return $null
  }

  $pattern = "href=`"/jqssun/android-lineage-qemu/releases/download/[^`"]*$([regex]::Escape($AssetSubstring))[^`"]*`""
  if ($page -match $pattern) {
    $path = ($Matches[0] -replace '^href="', '' -replace '"$', '')
    return "https://github.com$path"
  }

  Write-NucleusError "no jqssun asset matching '$AssetSubstring' in release $Tag"
  return $null
}

function Invoke-AndroidDownloadUserdebugRecovery {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [Parameter(Mandatory)]
    [string]$ImagesDir
  )

  $suffix = Get-AndroidRecoveryAssetSuffix -Vm $Vm
  $img = Join-Path $ImagesDir 'recovery userdebug.img'
  $assetName = "recovery_${suffix}-userdebug.img"
  $downloadUrl = "https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$assetName"

  $tag = Get-AndroidJqssunReleaseTagForAsset -AssetName $assetName
  if (-not $tag) { return $false }

  $tagFile = Join-Path $ImagesDir 'recovery userdebug.tag.json'
  if (Test-Path -LiteralPath $img -PathType Leaf) {
    $cachedTag = ''
    if (Test-Path -LiteralPath $tagFile -PathType Leaf) {
      $tagDoc = Get-Content -LiteralPath $tagFile -Raw | ConvertFrom-Json
      if ($null -ne $tagDoc.tag_name) { $cachedTag = [string]$tagDoc.tag_name }
    }
    if ($cachedTag -eq $tag) {
      Write-NucleusInfo "using cached userdebug recovery: $img"
      return $true
    }
    Write-NucleusInfo "jqssun release changed ($cachedTag → $tag); re-downloading userdebug recovery..."
    Remove-Item -LiteralPath $img -Force
  }
  else {
    Write-NucleusInfo "downloading userdebug recovery ($assetName)..."
  }

  try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $img -UseBasicParsing
  }
  catch {
    Write-NucleusError "failed to download userdebug recovery from $downloadUrl"
    return $false
  }
  if (-not (Test-Path -LiteralPath $img -PathType Leaf)) {
    Write-NucleusError "failed to download userdebug recovery from $downloadUrl"
    return $false
  }

  (@{ tag_name = $tag } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tagFile -Encoding UTF8
  Write-NucleusInfo "userdebug recovery ready: $img"
  return $true
}

function Test-AndroidGuestHasUserdebugRecovery {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  $state = Get-AndroidAdbPollState -Vm $Vm
  if ($state -notin @('recovery', 'sideload')) {
    return $false
  }

  $buildType = Get-AndroidShellGetprop -Vm $Vm -Name 'ro.build.type'
  $debuggable = Get-AndroidShellGetprop -Vm $Vm -Name 'ro.debuggable'
  if ($buildType -in @('userdebug', 'eng')) { return $true }
  return ($debuggable -eq '1')
}

function Invoke-AndroidEnsureUserdebugRecovery {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [Parameter(Mandatory)]
    [string]$ImagesDir
  )

  $img = Join-Path $ImagesDir 'recovery userdebug.img'
  $fbSerial = Get-AndroidFastbootSerial -Vm $Vm

  if (-not (Test-Path -LiteralPath $img -PathType Leaf)) {
    Write-NucleusError "userdebug recovery image missing: $img"
    return $false
  }

  if ((Get-AndroidFastbootListState -Vm $Vm) -eq 'fastboot') {
    Write-NucleusInfo "guest already in fastboot on $fbSerial"
  }
  elseif (Test-AndroidGuestHasUserdebugRecovery -Vm $Vm) {
    $buildType = Get-AndroidShellGetprop -Vm $Vm -Name 'ro.build.type'
    $debuggable = Get-AndroidShellGetprop -Vm $Vm -Name 'ro.debuggable'
    Write-NucleusInfo "userdebug recovery is active on the guest (ro.build.type=$buildType, ro.debuggable=$debuggable)"
    return $true
  }
  else {
    Write-NucleusInfo 'flashing userdebug recovery for MindTheGapps sideload...'
    Write-NucleusInfo 'manual step: in LineageOS Recovery, open Advanced → Enter fastboot (stock recovery cannot flash over ADB)'
    if (-not (Wait-AndroidFastboot -Vm $Vm -TimeoutSeconds 180)) {
      return $false
    }
  }

  & fastboot -s $fbSerial flash recovery $img
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "fastboot flash recovery failed on $fbSerial; confirm Advanced → Enter fastboot is active on the VM"
    return $false
  }

  # check-suppress:suppression_doc: fastboot reboot after flash is best-effort; guest may already be rebooting to recovery.
  & fastboot -s $fbSerial reboot 2>$null
  Write-NucleusInfo 'userdebug recovery flashed; guest should reboot to recovery'
  Write-NucleusInfo 'manual step: in recovery, enable ADB (Advanced → Enable ADB) before sideload can continue'
  Start-Sleep -Seconds 10
  return $true
}

function Wait-AndroidAdbRecovery {
  param(
    [Parameter(Mandatory)]
    [object]$Vm,
    [int]$TimeoutSeconds = 300
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "waiting for recovery ADB on $serial (timeout ${TimeoutSeconds}s)..."
  $elapsed = 0
  $lastHint = -30

  while ($elapsed -lt $TimeoutSeconds) {
    $state = Get-AndroidAdbPollState -Vm $Vm
    switch ($state) {
      { $_ -in @('recovery', 'sideload') } { return $true }
      'unauthorized' {
        if ($elapsed -ge ($lastHint + 30)) {
          Write-NucleusInfo 'ADB unauthorized — in userdebug recovery, enable ADB (Advanced → Enable ADB)'
          $lastHint = $elapsed
        }
      }
      'device' {
        if ($elapsed -ge ($lastHint + 30)) {
          Write-NucleusInfo 'guest is booted to system; boot LineageOS Recovery instead (power off → Reboot to recovery)'
          $lastHint = $elapsed
        }
      }
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
  }

  $final = Get-AndroidAdbPollState -Vm $Vm
  if ($final -eq 'unauthorized') {
    Write-NucleusError "timed out waiting for recovery ADB on $serial; enable ADB in recovery (Advanced → Enable ADB)"
  }
  else {
    Write-NucleusError "timed out waiting for recovery ADB on $serial (state: $final); boot LineageOS Recovery"
  }
  return $false
}

function Get-AndroidQemuImgPath {
  $scoopQemuDir = Join-Path $env:USERPROFILE 'scoop\apps\qemu\current'
  $qemuImg = Join-Path $scoopQemuDir 'qemu-img.exe'
  if (Test-Path -LiteralPath $qemuImg -PathType Leaf) {
    return $qemuImg
  }
  $inPath = Get-Command qemu-img -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe whether qemu-img is on PATH; absent tool handled below.
  if ($inPath) { return $inPath.Source }
  return $null
}

function Test-AndroidQcow2Image {
  param(
    [Parameter(Mandatory)]
    [string]$ImagePath,
    [Parameter(Mandatory)]
    [string]$Label,
    [Parameter(Mandatory)]
    [long]$MinVirtualSize
  )

  if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
    Write-NucleusError "$Label not found: $ImagePath"
    return $false
  }

  $fileInfo = Get-Item -LiteralPath $ImagePath
  if ($fileInfo.Length -le 0) {
    Write-NucleusError "$Label is empty or unreadable: $ImagePath"
    return $false
  }

  $qemuImg = Get-AndroidQemuImgPath
  if (-not $qemuImg) {
    Write-NucleusWarning "qemu-img not found; skipping qcow2 validation for $Label"
    return $true
  }

  $infoJson = & $qemuImg info --output=json $ImagePath 2>$null  # check-suppress:suppression_doc: qemu-img prints warnings to stderr; exit code checked immediately after.
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($infoJson | Out-String))) {
    Write-NucleusError "qemu-img could not read $Label`: $ImagePath"
    return $false
  }

  $info = ($infoJson | Out-String) | ConvertFrom-Json
  if ([string]$info.format -ne 'qcow2') {
    Write-NucleusError "$Label has unexpected format '$($info.format)' (expected qcow2): $ImagePath"
    return $false
  }

  $virtualSize = [long]$info.'virtual-size'
  if ($virtualSize -lt $MinVirtualSize) {
    Write-NucleusError "${Label} virtual size $virtualSize is below minimum $MinVirtualSize`: $ImagePath"
    return $false
  }

  return $true
}
