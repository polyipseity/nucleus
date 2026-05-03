<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Applies the WinGet DSC configuration and provisions SSH and GPG keys from
  the SOPS-encrypted secret files in src/secrets.

.PARAMETER ConfigPath
  Path to the WinGet DSC YAML file.
  Defaults to src/hosts/windows/configuration.dsc.yaml.

.PARAMETER Help
  Show this help message and exit.

.PARAMETER SecretsDir
  Path to the directory containing SOPS-encrypted .yml secret files.
  Defaults to src/secrets.

.EXAMPLE
  .\src\hosts\windows\apply.ps1
  Apply the full Windows configuration.

.EXAMPLE
  .\src\hosts\windows\apply.ps1 -Help
  Show this help message.
#>
[CmdletBinding()]
param(
  [Parameter()]
  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "configuration.dsc.yaml"),

  [Alias("h")]
  [Parameter()]
  [switch]$Help,

  [Parameter()]
  [string]$SecretsDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets")
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

function Get-NucleusSecrets {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output-format", "json", $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    Write-Host "Found host SSH key. Trying host-key decryption first..." -ForegroundColor Green
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Host "Host-key decryption failed. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  if (-not $secretKeyInfo -or -not ($secretKeyInfo -match "^(sec|ssb):")) {
    throw "No GPG secret keys detected. Import your encryption subkey before applying."
  }

  Write-Host "Decrypting with GPG keyring..." -ForegroundColor Cyan
  return (& $SopsExe @sopsArgs | ConvertFrom-Json)
}

function Resolve-ManagedExecutable {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CandidatePaths,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  foreach ($candidatePath in $CandidatePaths) {
    if ($candidatePath -and (Test-Path -Path $candidatePath)) {
      return $candidatePath
    }
  }

  throw "Unable to resolve managed executable path for '$Name'."
}

$resolvedConfig = Resolve-Path -Path $ConfigPath

Write-Host "Applying WinGet DSC: $resolvedConfig" -ForegroundColor Cyan
winget configure --accept-configuration-agreements --disable-interactivity "$resolvedConfig"

$gpgExe = Resolve-ManagedExecutable -Name "gpg" -CandidatePaths @(
  (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "GnuPG\bin\gpg.exe"),
  (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\gpg.exe"),
  (Join-Path -Path $env:ProgramFiles -ChildPath "GnuPG\bin\gpg.exe")
)

$sopsExe = Resolve-ManagedExecutable -Name "sops" -CandidatePaths @(
  (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\sops.exe"),
  (Join-Path -Path $env:ProgramFiles -ChildPath "sops\sops.exe")
)

if (-not (Test-Path -Path $SecretsDir)) {
  Write-Host "No secrets directory found at $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
  return
}

$secretFiles = @(Get-ChildItem -Path $SecretsDir -Filter "*.yml" | Sort-Object Name)

if ($secretFiles.Count -eq 0) {
  Write-Host "No .yml secret files found in $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
  return
}

$hostKeyPath = Join-Path -Path $env:PROGRAMDATA -ChildPath "ssh\ssh_host_ed25519_key"

$sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
if (-not (Test-Path -Path $sshDir)) {
  New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

foreach ($secretFile in $secretFiles) {
  Write-Host "Processing secrets from: $($secretFile.Name)" -ForegroundColor Cyan
  $jsonSecrets = Get-NucleusSecrets -FilePath $secretFile.FullName -GpgExe $gpgExe -HostKeyPath $hostKeyPath -SopsExe $sopsExe

  if ($jsonSecrets.PSObject.Properties['ssh_keys']) {
    foreach ($key in @($jsonSecrets.ssh_keys | Sort-Object name)) {
      $keyPath = Join-Path -Path $sshDir -ChildPath $key.name
      $existingValue = if (Test-Path -Path $keyPath) {
        Get-Content -Path $keyPath -Raw
      }
      else {
        ""
      }

      if ($existingValue -ne $key.value) {
        $key.value | Out-File -FilePath $keyPath -Encoding ascii -NoNewline
        Write-Host "  Updated SSH key: $($key.name)" -ForegroundColor Cyan
      }
    }
  }

  if ($jsonSecrets.PSObject.Properties['gpg_imports']) {
    foreach ($gpgKey in @($jsonSecrets.gpg_imports | Sort-Object name)) {
      $tempPath = [System.IO.Path]::GetTempFileName()

      try {
        $gpgKey.value | Out-File -FilePath $tempPath -Encoding ascii -NoNewline
        & $gpgExe --batch --import "$tempPath" | Out-Null
        Write-Host "  Imported GPG material: $($gpgKey.name)" -ForegroundColor Cyan
      }
      finally {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
