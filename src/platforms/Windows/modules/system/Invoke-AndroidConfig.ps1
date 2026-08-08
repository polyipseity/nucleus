<#
.SYNOPSIS
  Android post-provision configuration and reset for Windows nucleus-vm.

.DESCRIPTION
  PowerShell port of src/scripts/vms/android-config.sh, android-magisk.sh, and
  android-fake-wifi.sh, plus Invoke-AndroidReset (vm_build_android reset path).

.NOTES
  Dot-sources VMAndroid.ps1. Requires Format-NucleusOutput in caller scope.
#>

$script:AndroidNucleusMagiskMarker = 'android-magisk.tag.json'
$script:AndroidVmType = 'Android'
$script:AndroidRecoveryImg = 'recovery userdebug.img'
$script:AndroidRecoveryTag = 'recovery userdebug.tag.json'
$script:AndroidBootImg = 'boot.img'
$script:AndroidBootTag = 'boot.tag.json'
$script:AndroidMagiskApk = 'Magisk.apk'
$script:AndroidBootMagiskPatched = 'boot Magisk patched.img'
$script:AndroidGappsZip = 'GApps.zip'
$script:AndroidMagiskPatchKit = 'Magisk patch kit'
$script:AndroidLineageZip = 'Lineage download.zip'
$script:AndroidLineageExtract = 'Lineage extract'
$script:AndroidGsiDownloadZip = 'GSI download.zip'
$script:AndroidNucleusMagiskPatchRemote = '/data/local/tmp/nucleus-magisk-patch'
$script:AndroidNucleusMagiskStockBootRemote = '/data/local/tmp/nucleus-stock-boot.img'
$script:AndroidNucleusRootPropsService = '/data/adb/service.d/nucleus-root-props.sh'
$script:AndroidNucleusFakeWifiService = '/data/adb/service.d/nucleus-fake-wifi.sh'
$script:AndroidNucleusFakeWifiAdbProbeS = 3
$script:AndroidNucleusFakeWifiAsyncKickoffS = 5
$script:AndroidNucleusFakeWifiAsyncGraceS = 3

function Get-AndroidTypeSrcDir {
  param(
    [Parameter(Mandatory)]
    [string]$SrcDir
  )

  return (Join-Path $SrcDir $script:AndroidVmType)
}

function Get-AndroidGuestScriptPath {
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [ValidateSet('setup', 'revert')]
    [string]$Kind
  )

  $fileName = if ($Kind -eq 'setup') { 'android-fake-wifi-guest-setup.sh' } else { 'android-fake-wifi-guest-revert.sh' }
  return (Join-Path $RepoRoot "src\scripts\vms\$fileName")
}

function Get-AndroidGuestScriptContent {
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [ValidateSet('setup', 'revert')]
    [string]$Kind
  )

  Assert-AndroidTool -Name 'shellcheck'
  $path = Get-AndroidGuestScriptPath -RepoRoot $RepoRoot -Kind $Kind
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Write-NucleusError "guest fake-wifi script not found: $path"
    exit 1
  }

  & shellcheck -x $path
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "shellcheck failed for guest fake-wifi script: $path"
    exit 1
  }

  return (Get-Content -LiteralPath $path -Raw)
}

function Get-AndroidMagiskApkLibDir {
  param(
    [Parameter(Mandatory)]
    [object]$Vm
  )

  switch (Get-AndroidVmArch -VmType ([string]$Vm.type)) {
    'aarch64' { return 'arm64-v8a' }
    'x86_64' { return 'x86_64' }
    'arm' { return 'armeabi-v7a' }
    { $_ -in @('i386', 'x86') } { return 'x86' }
    default {
      Write-NucleusError "unsupported guest architecture for Magisk patching: $(Get-AndroidVmArch -VmType ([string]$Vm.type))"
      exit 1
    }
  }
}

function Invoke-AndroidEnableUsbDebugging {
  param([Parameter(Mandatory)][object]$Vm)

  $serial = Get-AndroidAdbSerial -Vm $Vm
  & adb -s $serial shell "su -c 'settings put global development_settings_enabled 1 && settings put global adb_enabled 1'"
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError 'failed to enable Developer options and USB debugging via settings'
    return $false
  }
  Start-Sleep -Seconds 2
  return $true
}

function Test-AndroidGuestHasMagiskSu {
  param([Parameter(Mandatory)][object]$Vm)

  if ((Get-AndroidAdbPollState -Vm $Vm) -ne 'device') { return $false }
  $serial = Get-AndroidAdbSerial -Vm $Vm
  $uid = & adb -s $serial shell 'su -c id -u' 2>$null
  return ((($uid | Out-String) -replace "`r", '').Trim() -eq '0')
}

function Get-AndroidSuGetprop {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$Name
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $value = & adb -s $serial shell "su -c getprop $Name" 2>$null
  if (-not $value) { return '' }
  return (($value | Out-String) -replace "`r`n", '').Trim()
}

function Get-AndroidRootPropsBootScript {
  return @'
#!/system/bin/sh
# persist.sys.root_access is already persist.*; rewrite is idempotent.
resetprop persist.sys.root_access 3
'@
}

function Invoke-AndroidRestoreRoDebuggableUser {
  param([Parameter(Mandatory)][object]$Vm)

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $debuggable = Get-AndroidSuGetprop -Vm $Vm -Name 'ro.debuggable'
  if ($debuggable -eq '1') {
    Write-NucleusInfo 'repairing ro.debuggable (was 1; restoring 0 for user build)...'
    & adb -s $serial shell "su -c resetprop ro.debuggable 0"
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError 'failed to restore ro.debuggable to 0'
      return $false
    }
  }
  return $true
}

function Test-AndroidRootPropsViaSu {
  param([Parameter(Mandatory)][object]$Vm)

  $rootAccess = Get-AndroidSuGetprop -Vm $Vm -Name 'persist.sys.root_access'
  if ($rootAccess -ne '3') {
    Write-NucleusError "persist.sys.root_access is $rootAccess (expected 3) after --root"
    return $false
  }

  $debuggable = Get-AndroidSuGetprop -Vm $Vm -Name 'ro.debuggable'
  if ($debuggable -ne '0') {
    Write-NucleusError "ro.debuggable is $debuggable (expected 0) after --root; re-run --root to repair"
    return $false
  }
  return $true
}

function Test-AndroidDevOptionsSmoke {
  param([Parameter(Mandatory)][object]$Vm)

  $serial = Get-AndroidAdbSerial -Vm $Vm
  & adb -s $serial shell 'am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS' 2>$null | Out-Null
  Start-Sleep -Seconds 2
  $log = & adb -s $serial logcat -d -t 30 2>$null
  if ((($log | Out-String) -match 'failed to set system property')) {
    Write-NucleusError 'Developer options smoke test failed (Settings property write error); ro.debuggable must stay 0'
    return $false
  }
  return $true
}

function Invoke-AndroidPersistRootPropsService {
  param([Parameter(Mandatory)][object]$Vm)

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $servicePath = $script:AndroidNucleusRootPropsService
  $bootScript = Get-AndroidRootPropsBootScript
  $persistCmd = @"
mkdir -p /data/adb/service.d && cat > $servicePath <<'EOF'
$bootScript
EOF
chmod 755 $servicePath
"@

  & adb -s $serial shell "su -c $(ConvertTo-ShSingleQuoted $persistCmd)"
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "failed to persist root props boot script at $servicePath"
    return $false
  }
  return $true
}

function ConvertTo-ShSingleQuoted {
  param([Parameter(Mandatory)][string]$Value)
  return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Invoke-AndroidConfigRoot {
  param([Parameter(Mandatory)][object]$Vm)

  if (-not (Wait-AndroidAdbAuthorized -Vm $Vm -TimeoutSeconds 600)) { return $false }

  $state = Get-AndroidAdbPollState -Vm $Vm
  if ($state -ne 'device') {
    Write-NucleusError "rooted debugging requires booted system (adb state device), got: $state"
    return $false
  }

  if (-not (Test-AndroidGuestHasMagiskSu -Vm $Vm)) {
    Write-NucleusError 'rooted debugging requires Magisk su; run --magisk first'
    return $false
  }

  if (-not (Invoke-AndroidRestoreRoDebuggableUser -Vm $Vm)) { return $false }
  if (-not (Invoke-AndroidEnableUsbDebugging -Vm $Vm)) { return $false }

  $serial = Get-AndroidAdbSerial -Vm $Vm
  & adb -s $serial shell 'su -c resetprop persist.sys.root_access 3'
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError 'failed to apply persist.sys.root_access on guest'
    return $false
  }

  if (-not (Invoke-AndroidPersistRootPropsService -Vm $Vm)) { return $false }
  if (-not (Test-AndroidRootPropsViaSu -Vm $Vm)) { return $false }

  if (-not (Test-AndroidGuestHasMagiskSu -Vm $Vm)) {
    Write-NucleusError 'Magisk su not available after rooted debugging apply'
    return $false
  }

  if (-not (Test-AndroidDevOptionsSmoke -Vm $Vm)) { return $false }

  Write-NucleusInfo "rooted debugging enabled on $serial (Magisk su, persist.sys.root_access=3); next: --fake-wifi"
  return $true
}

function Get-AndroidBootImagePath {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$SrcDir
  )

  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $SrcDir
  $suffix = Get-AndroidRecoveryAssetSuffix -Vm $Vm
  $asset = "boot_${suffix}.img"
  $img = Join-Path $androidSrcDir $script:AndroidBootImg
  $downloadUrl = "https://github.com/jqssun/android-lineage-qemu/releases/latest/download/$asset"

  $tag = Get-AndroidJqssunReleaseTagForAsset -AssetName $asset
  if (-not $tag) { return $null }

  $tagFile = Join-Path $androidSrcDir $script:AndroidBootTag
  if (Test-Path -LiteralPath $img -PathType Leaf) {
    $cachedTag = ''
    if (Test-Path -LiteralPath $tagFile -PathType Leaf) {
      $tagDoc = Get-Content -LiteralPath $tagFile -Raw | ConvertFrom-Json
      if ($null -ne $tagDoc.tag_name) { $cachedTag = [string]$tagDoc.tag_name }
    }
    if ($cachedTag -eq $tag) {
      Write-NucleusInfo "using cached boot image: $img"
      return $img
    }
    Write-NucleusInfo "jqssun release changed ($cachedTag → $tag); re-downloading boot image..."
    Remove-Item -LiteralPath $img -Force
  }
  else {
    Write-NucleusInfo "downloading boot image ($asset)..."
  }

  try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $img -UseBasicParsing
  }
  catch {
    Write-NucleusError "failed to download boot image from $downloadUrl"
    return $null
  }

  (@{ tag_name = $tag } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tagFile -Encoding UTF8
  Write-NucleusInfo "boot image ready: $img"
  return $img
}

function Get-AndroidMagiskApkPath {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$SrcDir
  )

  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $SrcDir
  $url = [string]$Vm.Android.magiskUrl
  $apk = Join-Path $androidSrcDir $script:AndroidMagiskApk
  if ([string]::IsNullOrWhiteSpace($url) -or $url -eq 'null') {
    Write-NucleusError 'Android.magiskUrl is not set in the manifest'
    return $null
  }

  if (Test-Path -LiteralPath $apk -PathType Leaf) {
    Write-NucleusInfo "using cached Magisk APK: $apk"
    return $apk
  }

  Write-NucleusInfo 'downloading Magisk APK...'
  try {
    Invoke-WebRequest -Uri $url -OutFile $apk -UseBasicParsing
  }
  catch {
    Write-NucleusError "failed to download Magisk from $url"
    return $null
  }

  Write-NucleusInfo "Magisk APK ready: $apk"
  return $apk
}

function Expand-AndroidMagiskPatchKit {
  param(
    [Parameter(Mandatory)][string]$MagiskApk,
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$OutDir
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $libDirName = Get-AndroidMagiskApkLibDir -Vm $Vm
  $requiredEntries = @(
    'assets/boot_patch.sh',
    'assets/util_functions.sh',
    'assets/stub.apk',
    "lib/$libDirName/libmagisk.so",
    "lib/$libDirName/libmagiskboot.so",
    "lib/$libDirName/libmagiskinit.so",
    "lib/$libDirName/libinit-ld.so"
  )

  if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

  $zip = [System.IO.Compression.ZipFile]::OpenRead($MagiskApk)
  try {
    foreach ($entryName in $requiredEntries) {
      $entry = $zip.GetEntry($entryName)
      if ($null -eq $entry) {
        Write-NucleusError "failed to extract Magisk patch kit from $MagiskApk (missing $entryName)"
        return $false
      }
      $dest = Join-Path $OutDir ($entryName -replace '/', [IO.Path]::DirectorySeparatorChar)
      $parent = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
    }
  }
  finally {
    $zip.Dispose()
  }

  $bootPatch = Join-Path $OutDir 'assets\boot_patch.sh'
  if (-not (Test-Path -LiteralPath $bootPatch -PathType Leaf)) {
    Write-NucleusError "Magisk APK is missing assets/boot_patch.sh ($MagiskApk)"
    return $false
  }

  Move-Item -LiteralPath $bootPatch -Destination (Join-Path $OutDir 'boot_patch.sh') -Force
  Move-Item -LiteralPath (Join-Path $OutDir 'assets\util_functions.sh') -Destination (Join-Path $OutDir 'util_functions.sh') -Force
  Move-Item -LiteralPath (Join-Path $OutDir 'assets\stub.apk') -Destination (Join-Path $OutDir 'stub.apk') -Force
  # check-suppress:suppression_doc: assets dir may already be gone after mv of boot_patch.sh and stub.apk.
  Remove-Item -LiteralPath (Join-Path $OutDir 'assets') -Recurse -Force -ErrorAction SilentlyContinue

  $pairs = @(
    @{ Src = 'libmagisk.so'; Dst = 'magisk' },
    @{ Src = 'libmagiskboot.so'; Dst = 'magiskboot' },
    @{ Src = 'libmagiskinit.so'; Dst = 'magiskinit' },
    @{ Src = 'libinit-ld.so'; Dst = 'init-ld' }
  )
  $libSourceDir = Join-Path $OutDir "lib\$libDirName"
  foreach ($pair in $pairs) {
    $srcPath = Join-Path $libSourceDir $pair.Src
    if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) {
      Write-NucleusError "Magisk APK is missing lib/$libDirName/$($pair.Src)"
      return $false
    }
    Copy-Item -LiteralPath $srcPath -Destination (Join-Path $OutDir $pair.Dst) -Force
  }

  Remove-Item -LiteralPath (Join-Path $OutDir 'lib') -Recurse -Force
  return $true
}

function Invoke-AndroidMagiskGuestPatchBoot {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$BootImg,
    [Parameter(Mandatory)][string]$OutImg,
    [Parameter(Mandatory)][string]$MagiskApk,
    [Parameter(Mandatory)][string]$SrcDir
  )

  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $SrcDir
  $serial = Get-AndroidAdbSerial -Vm $Vm
  $stage = Join-Path $androidSrcDir $script:AndroidMagiskPatchKit
  $remoteOut = "$($script:AndroidNucleusMagiskPatchRemote)/new-boot.img"

  if (-not (Expand-AndroidMagiskPatchKit -MagiskApk $MagiskApk -Vm $Vm -OutDir $stage)) {
    return $false
  }

  Write-NucleusInfo "patching boot image with Magisk on guest $serial..."
  & adb -s $serial shell "rm -rf $($script:AndroidNucleusMagiskPatchRemote) $($script:AndroidNucleusMagiskStockBootRemote)"
  $stagePush = Join-Path $stage '.'
  & adb -s $serial push $stagePush $script:AndroidNucleusMagiskPatchRemote/
  & adb -s $serial push $BootImg $script:AndroidNucleusMagiskStockBootRemote
  & adb -s $serial shell "chmod 755 $($script:AndroidNucleusMagiskPatchRemote)/magisk $($script:AndroidNucleusMagiskPatchRemote)/magiskboot $($script:AndroidNucleusMagiskPatchRemote)/magiskinit $($script:AndroidNucleusMagiskPatchRemote)/init-ld $($script:AndroidNucleusMagiskPatchRemote)/boot_patch.sh"

  & adb -s $serial shell "cd $($script:AndroidNucleusMagiskPatchRemote) && BOOTMODE=true sh ./boot_patch.sh $($script:AndroidNucleusMagiskStockBootRemote)"
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError 'Magisk boot_patch.sh failed on guest'
    return $false
  }

  & adb -s $serial pull $remoteOut $OutImg
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "failed to pull patched boot image from guest (expected $remoteOut)"
    return $false
  }

  # check-suppress:suppression_doc: remote cleanup is best-effort after a successful pull.
  & adb -s $serial shell "rm -rf $($script:AndroidNucleusMagiskPatchRemote) $($script:AndroidNucleusMagiskStockBootRemote)" 2>$null
  Write-NucleusInfo "patched boot image: $OutImg"
  return $true
}

function Invoke-AndroidMagiskFlashBoot {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$PatchedBootImg
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $fbSerial = Get-AndroidFastbootSerial -Vm $Vm

  Write-NucleusInfo "rebooting to fastboot on $serial (VM: Recovery → Advanced → Enter fastboot if needed)..."
  # check-suppress:suppression_doc: reboot bootloader may fail when already in fastboot; fastboot_wait handles the next state.
  & adb -s $serial reboot bootloader 2>$null

  if (-not (Wait-AndroidFastboot -Vm $Vm -TimeoutSeconds 180)) { return $false }

  & fastboot -s $fbSerial flash boot $PatchedBootImg
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "fastboot flash boot failed on $fbSerial"
    return $false
  }

  # check-suppress:suppression_doc: fastboot reboot after flash is best-effort; guest may already be rebooting.
  & fastboot -s $fbSerial reboot 2>$null
  Write-NucleusInfo 'flashed Magisk boot image; waiting for system boot...'
  return $true
}

function Invoke-AndroidMagiskInstallApk {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$MagiskApk
  )

  if (-not (Wait-AndroidAdbBootCompleted -Vm $Vm -TimeoutSeconds 600)) { return $false }

  $serial = Get-AndroidAdbSerial -Vm $Vm
  Write-NucleusInfo "installing Magisk APK on $serial..."
  for ($attempt = 0; $attempt -lt 12; $attempt++) {
    & adb -s $serial install -r $MagiskApk
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($attempt -lt 11) {
      Write-NucleusInfo 'Magisk APK install not ready yet (guest may still be booting); retrying...'
      Start-Sleep -Seconds 10
      # check-suppress:suppression_doc: guest may still be booting between Magisk APK install retries.
      Wait-AndroidAdbBootCompleted -Vm $Vm -TimeoutSeconds 120 | Out-Null
    }
  }

  Write-NucleusError 'failed to install Magisk APK; tap Allow USB debugging and retry'
  return $false
}

function Invoke-AndroidInstallAdbKeyViaSu {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$PubkeyPath
  )

  if (-not (Test-AndroidGuestHasMagiskSu -Vm $Vm)) {
    Write-NucleusError 'Magisk su is required to install adb_keys on a booted user build'
    return $false
  }

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $remote = '/sdcard/nucleus-adbkey.pub'
  & adb -s $serial push $PubkeyPath $remote
  $cmd = "mkdir -p /data/misc/adb && cp $remote /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && restorecon /data/misc/adb/adb_keys 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys && rm -f $remote && setprop ctl.restart adbd"
  & adb -s $serial shell "su -c $(ConvertTo-ShSingleQuoted $cmd)"
  return ($LASTEXITCODE -eq 0)
}

function Invoke-AndroidInstallAdbKey {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$PubkeyPath
  )

  $serial = Get-AndroidAdbSerial -Vm $Vm
  & adb -s $serial push $PubkeyPath /data/misc/adb/adb_keys
  & adb -s $serial shell 'chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys'
  # check-suppress:suppression_doc: restorecon is unavailable on some recovery shells; chcon is the portable fallback.
  & adb -s $serial shell 'restorecon /data/misc/adb/adb_keys 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys' 2>$null
  # check-suppress:suppression_doc: best-effort adbd restart after adb_keys install; verified via authorized ADB probe.
  & adb -s $serial shell 'setprop ctl.restart adbd' 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Invoke-AndroidConfigMagisk {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$SrcDir
  )

  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $SrcDir
  $serial = Get-AndroidAdbSerial -Vm $Vm
  $patched = Join-Path $androidSrcDir $script:AndroidBootMagiskPatched

  if (-not (Wait-AndroidAdbAuthorized -Vm $Vm -TimeoutSeconds 600)) { return $false }

  $state = Get-AndroidAdbPollState -Vm $Vm
  if ($state -ne 'device') {
    Write-NucleusError "Magisk requires booted system (adb state device), got: $state"
    return $false
  }

  $build = Get-AndroidShellGetprop -Vm $Vm -Name 'ro.build.display.id'
  if ($build -match 'gsi') {
    Write-NucleusError "Magisk install targets Lineage only (detected: $build); boot Lineage, not GSI"
    return $false
  }

  if (Test-AndroidGuestHasMagiskSu -Vm $Vm) {
    Write-NucleusInfo "Magisk su is already available on $serial"
  }
  else {
    $boot = Get-AndroidBootImagePath -Vm $Vm -SrcDir $SrcDir
    if (-not $boot) { return $false }
    $apk = Get-AndroidMagiskApkPath -Vm $Vm -SrcDir $SrcDir
    if (-not $apk) { return $false }
    if (-not (Invoke-AndroidMagiskGuestPatchBoot -Vm $Vm -BootImg $boot -OutImg $patched -MagiskApk $apk -SrcDir $SrcDir)) { return $false }
    if (-not (Invoke-AndroidMagiskFlashBoot -Vm $Vm -PatchedBootImg $patched)) { return $false }
    if (-not (Wait-AndroidAdbBootCompleted -Vm $Vm -TimeoutSeconds 900)) {
      Write-NucleusError 'timed out waiting for boot after Magisk flash; complete setup wizard and tap Allow USB debugging'
      return $false
    }
    if (-not (Invoke-AndroidMagiskInstallApk -Vm $Vm -MagiskApk $apk)) { return $false }
    Write-NucleusInfo 'next: open Magisk app on VM; complete environment-fix if prompted, then re-run --magisk'

    $wait = 0
    while ($wait -lt 120) {
      if (Test-AndroidGuestHasMagiskSu -Vm $Vm) { break }
      Start-Sleep -Seconds 5
      $wait += 5
    }
    if (-not (Test-AndroidGuestHasMagiskSu -Vm $Vm)) {
      Write-NucleusError 'Magisk su not available; open Magisk app on VM, then retry --magisk'
      return $false
    }
  }

  $suffix = Get-AndroidRecoveryAssetSuffix -Vm $Vm
  $tag = Get-AndroidJqssunReleaseTagForAsset -AssetName "boot_${suffix}.img"
  if ($tag) {
    $marker = Join-Path $androidSrcDir $script:AndroidNucleusMagiskMarker
    (@{ tag_name = $tag; configured = $true } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $marker -Encoding UTF8
  }

  Write-NucleusInfo "Magisk installed on $serial; next: --root"
  return $true
}

function Invoke-AndroidFakeWifiAdbReconnect {
  param([Parameter(Mandatory)][string]$Serial)

  # check-suppress:suppression_doc: disconnect drops stale sessions; reconnect kicks the host-side transport.
  Invoke-AndroidExternalWithTimeout -TimeoutSeconds 5 -FilePath 'adb' -ArgumentList @('disconnect', $Serial) | Out-Null
  # check-suppress:suppression_doc: idempotent ADB reconnect while guest link transitions.
  Invoke-AndroidExternalWithTimeout -TimeoutSeconds 5 -FilePath 'adb' -ArgumentList @('reconnect') | Out-Null
  # check-suppress:suppression_doc: idempotent ADB connect while guest link transitions.
  Invoke-AndroidExternalWithTimeout -TimeoutSeconds 10 -FilePath 'adb' -ArgumentList @('connect', $Serial) | Out-Null
}

function Test-AndroidFakeWifiAdbProbe {
  param([Parameter(Mandatory)][string]$Serial)

  $stdout = $null
  $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds $script:AndroidNucleusFakeWifiAdbProbeS `
    -FilePath 'adb' -ArgumentList @('-s', $Serial, 'shell', 'su -c id -u') -StdOut ([ref]$stdout)
  if ($exitCode -ne 0) { return $false }
  return ((($stdout | Out-String) -replace "`r", '').Trim() -eq '0')
}

function Test-AndroidFakeWifiAdbShellProbe {
  param([Parameter(Mandatory)][string]$Serial)

  $stdout = $null
  $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds $script:AndroidNucleusFakeWifiAdbProbeS `
    -FilePath 'adb' -ArgumentList @('-s', $Serial, 'shell', 'echo 1') -StdOut ([ref]$stdout)
  if ($exitCode -ne 0) { return $false }
  return ((($stdout | Out-String) -replace "`r", '').Trim() -eq '1')
}

function Test-AndroidFakeWifiAdbEnsureAfterLinkChange {
  param([Parameter(Mandatory)][string]$Serial)

  Invoke-AndroidFakeWifiAdbReconnect -Serial $Serial
  return (Test-AndroidFakeWifiAdbProbe -Serial $Serial)
}

function Test-AndroidFakeWifiAdbEnsure {
  param([Parameter(Mandatory)][string]$Serial)

  if (Test-AndroidFakeWifiAdbProbe -Serial $Serial) { return $true }
  if (-not (Test-AndroidFakeWifiAdbShellProbe -Serial $Serial)) {
    Invoke-AndroidFakeWifiAdbReconnect -Serial $Serial
  }
  return (Test-AndroidFakeWifiAdbProbe -Serial $Serial)
}

function Assert-AndroidFakeWifiRequireSu {
  param([Parameter(Mandatory)][string]$Serial)

  if (Test-AndroidFakeWifiAdbProbe -Serial $Serial) { return $true }
  if (Test-AndroidFakeWifiAdbShellProbe -Serial $Serial) {
    Write-NucleusError "Magisk su is not available on $Serial (adb shell works); open the Magisk app and retry"
  }
  else {
    Write-NucleusError "ADB is not reachable on $Serial; run adb disconnect && adb connect manually, then retry"
  }
  return $false
}

function Invoke-AndroidFakeWifiRunAsRoot {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$Command,
    [int]$TimeoutSeconds = 30
  )

  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds $TimeoutSeconds -FilePath 'adb' `
      -ArgumentList @('-s', $Serial, 'shell', "su -c $(ConvertTo-ShSingleQuoted $Command)")
    if ($exitCode -eq 0) { return $true }
    Invoke-AndroidFakeWifiAdbReconnect -Serial $Serial
  }
  return $false
}

function Invoke-AndroidFakeWifiRunGuestScript {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$ScriptContent,
    [switch]$Async
  )

  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ScriptContent))
  $timeout = if ($Async) { $script:AndroidNucleusFakeWifiAsyncKickoffS } else { 30 }
  $cmd = if ($Async) { "NUCLEUS_FAKE_WIFI_ASYNC=1 echo $b64 | base64 -d | sh" } else { "echo $b64 | base64 -d | sh" }
  return (Invoke-AndroidFakeWifiRunAsRoot -Serial $Serial -Command $cmd -TimeoutSeconds $timeout)
}

function Wait-AndroidFakeWifiAdbAfterAsync {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [int]$TimeoutSeconds = 30
  )

  Write-NucleusInfo "waiting for ADB on $Serial to recover (timeout ${TimeoutSeconds}s)..."
  Start-Sleep -Seconds $script:AndroidNucleusFakeWifiAsyncGraceS
  $elapsed = $script:AndroidNucleusFakeWifiAsyncGraceS
  while ($elapsed -lt $TimeoutSeconds) {
    if (Test-AndroidFakeWifiAdbEnsureAfterLinkChange -Serial $Serial) { return $true }
    Start-Sleep -Seconds 1
    $elapsed++
  }
  return $false
}

function Test-AndroidFakeWifiWlan0Up {
  param([Parameter(Mandatory)][string]$Serial)

  $stdout = $null
  $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds $script:AndroidNucleusFakeWifiAdbProbeS `
    -FilePath 'adb' -ArgumentList @('-s', $Serial, 'shell', "su -c $(ConvertTo-ShSingleQuoted 'ip link show wlan0')") -StdOut ([ref]$stdout)
  if ($exitCode -ne 0) { return $false }
  return (($stdout | Out-String) -match 'wlan0')
}

function Test-AndroidFakeWifiEth0Up {
  param([Parameter(Mandatory)][string]$Serial)

  $stdout = $null
  $exitCode = Invoke-AndroidExternalWithTimeout -TimeoutSeconds $script:AndroidNucleusFakeWifiAdbProbeS `
    -FilePath 'adb' -ArgumentList @('-s', $Serial, 'shell', "su -c $(ConvertTo-ShSingleQuoted 'ip link show eth0')") -StdOut ([ref]$stdout)
  if ($exitCode -ne 0) { return $false }
  return (($stdout | Out-String) -match 'eth0')
}

function Wait-AndroidFakeWifiReady {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [int]$TimeoutSeconds = 60
  )

  Write-NucleusInfo "waiting for guest VirtWifi setup on $Serial (ADB reconnects after join; timeout ${TimeoutSeconds}s)..."
  Start-Sleep -Seconds $script:AndroidNucleusFakeWifiAsyncGraceS
  $elapsed = $script:AndroidNucleusFakeWifiAsyncGraceS
  while ($elapsed -lt $TimeoutSeconds) {
    if ((Test-AndroidFakeWifiAdbEnsureAfterLinkChange -Serial $Serial) -and (Test-AndroidFakeWifiWlan0Up -Serial $Serial)) {
      return $true
    }
    Start-Sleep -Seconds 1
    $elapsed++
  }
  return $false
}

function Write-AndroidFakeWifiDiagnosticReport {
  param([Parameter(Mandatory)][string]$Serial)

  Write-NucleusInfo "fake Wi-Fi diagnostics for ${Serial}:"
  $diagCmd = 'uname -r; getprop ro.boot.wifi_impl; ls -la /lib/modules /vendor/lib/modules /vendor_dlkm/lib/modules 2>&1; find /vendor /odm /vendor_dlkm -name "virt_wifi*.ko" 2>/dev/null; zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_VIRT_WIFI|CONFIG_CFG80211" || :; ip link show'
  if (-not (Invoke-AndroidFakeWifiRunAsRoot -Serial $Serial -Command $diagCmd -TimeoutSeconds 30)) {
    Write-NucleusWarning 'could not collect fake Wi-Fi diagnostics (is Magisk su available?)'
  }
}

function Invoke-AndroidFakeWifiEnable {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$RepoRoot
  )

  Assert-AndroidTool -Name 'adb'

  if (-not (Assert-AndroidFakeWifiRequireSu -Serial $Serial)) { return $false }

  $setupScript = Get-AndroidGuestScriptContent -RepoRoot $RepoRoot -Kind 'setup'

  if (Test-AndroidFakeWifiWlan0Up -Serial $Serial) {
    Write-NucleusInfo "wlan0 already present on $Serial (VirtWifi already joined)"
  }
  else {
    Write-NucleusInfo "loading virt_wifi and creating wlan0 on $Serial (ADB will reconnect)..."
    if (-not (Invoke-AndroidFakeWifiRunGuestScript -Serial $Serial -ScriptContent $setupScript -Async)) {
      Write-AndroidFakeWifiDiagnosticReport -Serial $Serial
      Write-NucleusError 'failed to start fake Wi-Fi setup on guest'
      return $false
    }
    if (-not (Wait-AndroidFakeWifiReady -Serial $Serial -TimeoutSeconds 60)) {
      Write-AndroidFakeWifiDiagnosticReport -Serial $Serial
      Write-NucleusError 'ADB or wlan0 did not become ready after fake Wi-Fi setup'
      return $false
    }
  }

  $servicePath = $script:AndroidNucleusFakeWifiService
  $persistCmd = @"
mkdir -p /data/adb/service.d && cat > $servicePath <<'EOF'
$setupScript
EOF
chmod 755 $servicePath
"@
  if (Invoke-AndroidFakeWifiRunAsRoot -Serial $Serial -Command $persistCmd -TimeoutSeconds 2) {
    Write-NucleusInfo "persisted fake Wi-Fi startup at $servicePath"
  }
  else {
    Write-NucleusWarning 'could not persist fake Wi-Fi script (Magisk service.d may be unavailable); re-run after reboot if needed'
  }

  Write-NucleusInfo "fake Wi-Fi enabled on $Serial"
  return $true
}

function Invoke-AndroidFakeWifiRevert {
  param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$RepoRoot
  )

  Assert-AndroidTool -Name 'adb'

  if (-not (Assert-AndroidFakeWifiRequireSu -Serial $Serial)) { return $false }

  Write-NucleusInfo "reverting fake Wi-Fi on $Serial..."
  $hadWlan0 = Test-AndroidFakeWifiWlan0Up -Serial $Serial
  $revertScript = Get-AndroidGuestScriptContent -RepoRoot $RepoRoot -Kind 'revert'

  # check-suppress:suppression_doc: revert is best-effort; missing service file is acceptable.
  Invoke-AndroidFakeWifiRunAsRoot -Serial $Serial -Command "rm -f $($script:AndroidNucleusFakeWifiService)" `
    -TimeoutSeconds $script:AndroidNucleusFakeWifiAsyncKickoffS | Out-Null

  if ($hadWlan0) {
    # check-suppress:suppression_doc: guest link teardown runs async; ADB drops briefly on eth0 rename.
    Invoke-AndroidFakeWifiRunGuestScript -Serial $Serial -ScriptContent $revertScript -Async | Out-Null
    if (-not (Wait-AndroidFakeWifiAdbAfterAsync -Serial $Serial -TimeoutSeconds 30)) {
      Write-NucleusWarning "ADB did not recover within 30s after revert; if commands hang, run: adb disconnect $Serial && adb connect $Serial"
    }
  }
  elseif (Test-AndroidFakeWifiEth0Up -Serial $Serial) {
    Write-NucleusInfo "wlan0 already absent; eth0 is up on $Serial"
  }

  Write-NucleusInfo "fake Wi-Fi reverted on $Serial"
  return $true
}

function Show-AndroidConfigManual {
  @'
Android post-provision (jqssun LineageOS 23 user build)

Flags: --gapps --adb-keys --magisk --root --fake-wifi --fake-wifi-revert

--magisk installs Magisk su. --root enables Developer options and
persist.sys.root_access (ro.debuggable stays 0; Magisk su for automation). --fake-wifi needs Magisk su.

Recovery (GApps, optional ADB keys):
  1. nucleus-vm reset Android; start VM; boot LineageOS Recovery (factory-reset if needed).
  2. Recovery → Advanced → Enter fastboot.
  3. nucleus-vm android-config Android --gapps
  4. Recovery → Advanced → Enable ADB.
  5. Tap Install anyway when sideload asks about signature verification.
  6. Reboot system now.
  7. Optional: nucleus-vm android-config Android --adb-keys (skip if you will tap Allow on first boot).

Booted system:
  8. Finish setup wizard; enable USB debugging; tap Allow.
  9. nucleus-vm android-config Android --magisk
 10. Open Magisk app; complete environment-fix if prompted; re-run --magisk if needed.
 11. nucleus-vm android-config Android --root
 12. nucleus-vm android-config Android --fake-wifi
'@ | Write-Output
}

function Invoke-AndroidConfigGapp {
  param(
    [Parameter(Mandatory)][object]$Vm,
    [Parameter(Mandatory)][string]$SrcDir
  )

  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $SrcDir
  $serial = Get-AndroidAdbSerial -Vm $Vm
  $gappsUrl = [string]$Vm.Android.gappsUrl
  $gappsZip = Join-Path $androidSrcDir $script:AndroidGappsZip

  if ([string]::IsNullOrWhiteSpace($gappsUrl) -or $gappsUrl -eq 'null') {
    Write-NucleusError 'Android.gappsUrl is not set in the manifest'
    return $false
  }

  $state = Get-AndroidAdbPollState -Vm $Vm
  if ($state -eq 'device') {
    Write-NucleusError 'MindTheGapps requires LineageOS Recovery; guest is booted to system (device)'
    return $false
  }

  if (-not (Invoke-AndroidDownloadUserdebugRecovery -Vm $Vm -ImagesDir $androidSrcDir)) { return $false }
  if (-not (Invoke-AndroidEnsureUserdebugRecovery -Vm $Vm -ImagesDir $androidSrcDir)) { return $false }
  if (-not (Wait-AndroidAdbRecovery -Vm $Vm -TimeoutSeconds 300)) { return $false }

  if (Wait-AndroidAdbSideload -Vm $Vm -TimeoutSeconds 15) {
    Write-NucleusInfo "guest already in sideload mode on $serial"
  }
  else {
    $state = Get-AndroidAdbPollState -Vm $Vm
    if ($state -eq 'recovery') {
      Write-NucleusInfo "entering sideload mode on $serial..."
      # check-suppress:suppression_doc: reboot sideload may fail when already transitioning; sideload wait below handles the next state.
      & adb -s $serial reboot sideload 2>$null
    }
    if (-not (Wait-AndroidAdbSideload -Vm $Vm -TimeoutSeconds 120)) {
      Write-NucleusError 'guest did not enter sideload mode; from recovery select Apply update from ADB'
      return $false
    }
  }

  if (-not (Test-Path -LiteralPath $gappsZip -PathType Leaf)) {
    Write-NucleusInfo 'downloading MindTheGapps...'
    try {
      Invoke-WebRequest -Uri $gappsUrl -OutFile $gappsZip -UseBasicParsing
    }
    catch {
      Write-NucleusError "failed to download MindTheGapps from $gappsUrl"
      return $false
    }
  }
  else {
    Write-NucleusInfo "using cached MindTheGapps: $gappsZip"
  }

  Write-NucleusInfo 'tap Install anyway on the VM if sideload asks about signature verification'
  Write-NucleusInfo "sideloading MindTheGapps to $serial..."
  & adb -s $serial sideload $gappsZip
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError 'adb sideload failed; tap Install anyway on the VM if prompted, then retry'
    return $false
  }

  Write-NucleusInfo 'MindTheGapps sideload finished'
  Write-NucleusInfo 'next: reboot system; then --magisk, --root, --fake-wifi'
  return $true
}

function Invoke-AndroidConfigAdbKey {
  param([Parameter(Mandatory)][object]$Vm)

  $serial = Get-AndroidAdbSerial -Vm $Vm
  $pubkey = Join-Path $env:USERPROFILE '.android\adbkey.pub'

  if (-not (Test-Path -LiteralPath $pubkey -PathType Leaf)) {
    Write-NucleusError "host ADB public key not found: $pubkey (run adb once to generate keys)"
    return $false
  }

  $state = Get-AndroidAdbPollState -Vm $Vm
  switch ($state) {
    { $_ -in @('recovery', 'sideload') } {
      if (-not (Wait-AndroidAdbRecovery -Vm $Vm -TimeoutSeconds 300)) { return $false }
    }
    'device' {
      if (-not (Wait-AndroidAdbAuthorized -Vm $Vm -TimeoutSeconds 600)) { return $false }
    }
    'unauthorized' {
      Write-NucleusError 'ADB unauthorized; enable ADB in recovery (Advanced → Enable ADB) or tap Allow on booted Lineage'
      return $false
    }
    default {
      Write-NucleusError "ADB not reachable for key install (state: $state)"
      return $false
    }
  }

  $state = Get-AndroidAdbPollState -Vm $Vm
  switch ($state) {
    { $_ -in @('recovery', 'sideload') } {
      if (-not (Test-AndroidGuestShellIsRoot -Vm $Vm)) {
        Write-NucleusError 'recovery adb-keys requires root shell (Advanced → Enable ADB)'
        return $false
      }
      if (-not (Invoke-AndroidInstallAdbKey -Vm $Vm -PubkeyPath $pubkey)) { return $false }
    }
    'device' {
      if (-not (Test-AndroidGuestHasMagiskSu -Vm $Vm)) {
        Write-NucleusError 'booted adb-keys requires Magisk su (run --magisk first) or recovery --adb-keys before first boot'
        return $false
      }
      if (-not (Invoke-AndroidInstallAdbKeyViaSu -Vm $Vm -PubkeyPath $pubkey)) { return $false }
    }
    default {
      Write-NucleusError "guest must be in recovery or booted system for adb-keys; current state: $state"
      return $false
    }
  }

  Write-NucleusInfo "installed host ADB key on $serial ($state)"
  if ($state -in @('recovery', 'sideload')) {
    Write-NucleusInfo 'next: reboot system, then --magisk, --root, --fake-wifi'
  }
  return $true
}

function Resolve-AndroidVmIndex {
  param(
    [Parameter(Mandatory)]
    [object]$Manifest,
    [Parameter(Mandatory)]
    [string]$VmId
  )

  for ($i = 0; $i -lt @($Manifest.VMs).Count; $i++) {
    if ([string]$Manifest.VMs[$i].id -eq $VmId) {
      return $i
    }
  }
  return -1
}

function Invoke-AndroidConfig {
  <#
  .SYNOPSIS
    Post-provision Android guest configuration (GApps, ADB keys, Magisk, fake Wi-Fi).
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [string]$VmId,
    [Parameter(Mandatory)]
    [object]$Manifest,
    [Parameter(Mandatory)]
    [string]$VmDir,
    [Parameter()]
    [string[]]$ConfigFlags = @()
  )

  $vmIndex = Resolve-AndroidVmIndex -Manifest $Manifest -VmId $VmId
  if ($vmIndex -lt 0) {
    Write-NucleusError "VM '$VmId' not found in manifest"
    exit 1
  }

  $vm = $Manifest.VMs[$vmIndex]
  if ([string]$vm.type -ne 'Android') {
    Write-NucleusError "android-config is only supported for Android VMs ('$VmId' is type $($vm.type))"
    exit 1
  }

  $srcDir = Join-Path $VmDir 'src'

  $doGapps = $false
  $doAdbKeys = $false
  $doMagisk = $false
  $doRoot = $false
  $doFakeWifi = $false
  $doFakeWifiRevert = $false

  foreach ($flag in $ConfigFlags) {
    switch ($flag) {
      '--gapps' { $doGapps = $true }
      '--adb-keys' { $doAdbKeys = $true }
      '--adb-debug' {
        Write-NucleusError 'unknown flag: --adb-debug (did you mean --adb-keys?)'
        exit 1
      }
      '--root' { $doRoot = $true }
      '--magisk' { $doMagisk = $true }
      '--fake-wifi' { $doFakeWifi = $true }
      '--fake-wifi-revert' { $doFakeWifiRevert = $true }
      { $_ -in @('-h', '--help') } {
        Show-AndroidConfigManual
        return
      }
      default {
        Write-NucleusError "unsupported flag: $flag"
        exit 1
      }
    }
  }

  if (-not ($doGapps -or $doAdbKeys -or $doMagisk -or $doRoot -or $doFakeWifi -or $doFakeWifiRevert)) {
    Show-AndroidConfigManual
    return
  }

  Assert-AndroidTool -Name 'adb'
  Assert-AndroidTool -Name 'fastboot'
  if ($doFakeWifi -or $doFakeWifiRevert) {
    Assert-AndroidTool -Name 'shellcheck'
  }

  if ($doGapps) {
    if (-not (Invoke-AndroidConfigGapp -Vm $vm -SrcDir $srcDir)) { exit 1 }
  }
  if ($doAdbKeys) {
    if (-not (Invoke-AndroidConfigAdbKey -Vm $vm)) { exit 1 }
  }
  if ($doMagisk) {
    if (-not (Invoke-AndroidConfigMagisk -Vm $vm -SrcDir $srcDir)) { exit 1 }
  }
  if ($doRoot) {
    if (-not (Invoke-AndroidConfigRoot -Vm $vm)) { exit 1 }
  }
  if ($doFakeWifi) {
    if (-not (Wait-AndroidAdbAuthorized -Vm $vm -TimeoutSeconds 600)) {
      Write-NucleusError 'fake Wi-Fi requires booted Lineage with authorized ADB'
      exit 1
    }
    if (-not (Test-AndroidGuestHasMagiskSu -Vm $vm)) {
      Write-NucleusError 'fake Wi-Fi requires Magisk su; run --magisk first'
      exit 1
    }
    $serial = Get-AndroidAdbSerial -Vm $vm
    if (-not (Invoke-AndroidFakeWifiEnable -Serial $serial -RepoRoot $RepoRoot)) { exit 1 }
  }
  if ($doFakeWifiRevert) {
    if (-not (Wait-AndroidAdbAuthorized -Vm $vm -TimeoutSeconds 600)) {
      Write-NucleusError 'fake Wi-Fi revert requires booted Lineage with authorized ADB'
      exit 1
    }
    $serial = Get-AndroidAdbSerial -Vm $vm
    if (-not (Invoke-AndroidFakeWifiRevert -Serial $serial -RepoRoot $RepoRoot)) { exit 1 }
  }

  Write-NucleusInfo "android-config complete for '$VmId'"
}

function Invoke-AndroidReset {
  <#
  .SYNOPSIS
    Factory-reset Android VM user state by recreating data/<id>.qcow2.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [string]$VmId,
    [Parameter(Mandatory)]
    [object]$Manifest,
    [Parameter(Mandatory)]
    [string]$VmDir,
    [switch]$AcceptGsiLicense
  )

  $vmIndex = Resolve-AndroidVmIndex -Manifest $Manifest -VmId $VmId
  if ($vmIndex -lt 0) {
    Write-NucleusError "VM '$VmId' not found in manifest"
    exit 1
  }

  $vm = $Manifest.VMs[$vmIndex]
  if ([string]$vm.type -ne 'Android') {
    Write-NucleusError "reset is only supported for Android VMs ('$VmId' is type $($vm.type))"
    exit 1
  }

  if ($vm.shareDevDir -eq $true) {
    Write-NucleusError "shareDevDir is not supported for Android VM '$VmId'; Android does not support host filesystem sharing via QEMU"
    exit 1
  }

  $srcDir = Join-Path $VmDir 'src'
  $androidSrcDir = Get-AndroidTypeSrcDir -SrcDir $srcDir
  $dataDir = Join-Path $VmDir 'data'
  . (Join-Path $RepoRoot 'src\platforms\Windows\modules\SizeStrings.ps1')
  $minSizeBytes = [long](ConvertFrom-SizeString $vm.minImageSize)
  $diskBytes = [long](ConvertFrom-SizeString $vm.diskSize)

  $systemImageName = [string]$vm.Android.systemImage
  $userdataImageName = [string]$vm.Android.userdataImage
  $gsiImageName = [string]$vm.Android.gsiImage
  $gsiUrl = [string]$vm.Android.gsiUrl

  $systemImg = Join-Path $androidSrcDir $systemImageName
  $userdataImg = Join-Path $dataDir "$VmId.qcow2"
  $gsiImg = Join-Path $androidSrcDir $gsiImageName

  if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
  }

  # Step 1: ensure system image exists (download if missing; reset does not force upgrade)
  if (-not (Test-Path -LiteralPath $systemImg -PathType Leaf)) {
    Write-NucleusInfo "downloading LineageOS base image for '$VmId'..."
    $suffix = Get-AndroidRecoveryAssetSuffix -Vm $vm
    $tag = Get-AndroidJqssunReleaseTagForAsset -AssetName "boot_${suffix}.img"
    if (-not $tag) { exit 1 }
    $dlUrl = Get-AndroidJqssunAssetUrl -Tag $tag -AssetSubstring "UTM-VM-lineage-.*virtio_${suffix}.zip"
    if (-not $dlUrl) { exit 1 }

    $zipPath = Join-Path $androidSrcDir $script:AndroidLineageZip
    try {
      Invoke-WebRequest -Uri $dlUrl -OutFile $zipPath -UseBasicParsing
    }
    catch {
      Write-NucleusError 'failed to download LineageOS zip'
      exit 1
    }

    $extractDir = Join-Path $androidSrcDir $script:AndroidLineageExtract
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $largestQcow2 = Get-ChildItem -LiteralPath $extractDir -Filter '*.qcow2' -File -Recurse |
      Sort-Object -Property Length -Descending |
      Select-Object -First 1
    if ($null -eq $largestQcow2) {
      Write-NucleusError 'no qcow2 system image found inside extracted LineageOS bundle'
      exit 1
    }

    Copy-Item -LiteralPath $largestQcow2.FullName -Destination $systemImg -Force
    Remove-Item -LiteralPath $extractDir, $zipPath -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-AndroidQcow2Image -ImagePath $systemImg -Label "Android system image for $VmId" -MinVirtualSize $minSizeBytes)) {
      exit 1
    }
    Write-NucleusInfo "system image ready: $systemImg"
  }
  else {
    Write-NucleusInfo "system image already exists: $systemImg"
  }

  # Step 2: reset userdata disk
  $bundleUserdata = Join-Path $VmDir "$VmId.utm\Data\$userdataImageName"
  if (Test-Path -LiteralPath $userdataImg -PathType Leaf) {
    Write-NucleusInfo 'resetting Android userdata disk...'
    Remove-Item -LiteralPath $userdataImg -Force
  }
  elseif (Test-Path -LiteralPath $bundleUserdata -PathType Leaf) {
    Write-NucleusError "Android userdata for '$VmId' exists only in the UTM bundle ($bundleUserdata); move it manually to $userdataImg and re-run"
    exit 1
  }

  if (-not (Test-Path -LiteralPath $userdataImg -PathType Leaf)) {
    Write-NucleusInfo "creating userdata disk ($diskBytes bytes)..."
    $qemuImg = Get-AndroidQemuImgPath
    if (-not $qemuImg) {
      Write-NucleusError 'qemu-img not found; install QEMU via Scoop (scoop install qemu) or add it to PATH'
      exit 1
    }
    & $qemuImg create -f qcow2 $userdataImg $diskBytes
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError "failed to create Android userdata disk: $userdataImg"
      exit 1
    }
    if (-not (Test-AndroidQcow2Image -ImagePath $userdataImg -Label "Android userdata disk for $VmId" -MinVirtualSize $minSizeBytes)) {
      exit 1
    }
    Write-NucleusInfo "userdata disk ready: $userdataImg"
  }

  # Step 3: optional GSI image
  if (-not [string]::IsNullOrWhiteSpace($gsiUrl) -and $gsiUrl -ne 'null') {
    if (-not $AcceptGsiLicense) {
      Write-NucleusError "GSI license not accepted for '$VmId'; see https://developer.android.com/license"
      exit 1
    }
    Write-NucleusInfo 'GSI license: https://developer.android.com/license'
    if (-not (Test-Path -LiteralPath $gsiImg -PathType Leaf)) {
      Write-NucleusInfo 'downloading GSI system image...'
      $gsiZip = Join-Path $androidSrcDir $script:AndroidGsiDownloadZip
      try {
        Invoke-WebRequest -Uri $gsiUrl -OutFile $gsiZip -UseBasicParsing
      }
      catch {
        Write-NucleusError "failed to download GSI zip from $gsiUrl"
        exit 1
      }

      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zip = [System.IO.Compression.ZipFile]::OpenRead($gsiZip)
      try {
        $entry = $zip.GetEntry('system.img')
        if ($null -eq $entry) {
          Write-NucleusError 'GSI system.img not found in zip archive'
          exit 1
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $gsiImg, $true)
      }
      finally {
        $zip.Dispose()
      }
      Remove-Item -LiteralPath $gsiZip -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $gsiImg -PathType Leaf)) {
        Write-NucleusError 'GSI system.img not found after extraction'
        exit 1
      }
      Write-NucleusInfo "GSI system image ready: $gsiImg"
    }
    else {
      Write-NucleusInfo "GSI system image already exists: $gsiImg"
    }
  }
  else {
    Write-NucleusInfo 'no GSI URL set; skipping GSI download (Lineage-only)'
  }

  Write-NucleusInfo "reset complete for '$VmId'"
}
