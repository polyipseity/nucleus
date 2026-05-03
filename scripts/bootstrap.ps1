<#
.SYNOPSIS
  Bootstrap the nucleus environment for Windows.

.DESCRIPTION
  Applies the WinGet DSC configuration, installs bootstrap dependencies
  (Git, GnuPG, SOPS), and provisions SSH and GPG keys from the encrypted
  secrets file.

.PARAMETER ConfigPath
  Path to the WinGet DSC YAML file.
  Defaults to src/hosts/windows/configuration.dsc.yaml.

.PARAMETER Help
  Show this help message and exit.

.PARAMETER InstallDepsOnly
  Install bootstrap dependencies only; skip OS configuration and secrets
  provisioning.

.PARAMETER SecretsDir
  Path to the directory containing SOPS-encrypted .yml secret files.
  Defaults to src/secrets.

.EXAMPLE
  .\bootstrap.ps1
  Apply the full configuration.

.EXAMPLE
  .\bootstrap.ps1 -InstallDepsOnly
  Install bootstrap-managed dependencies only; skip secrets and OS config.

.EXAMPLE
  .\bootstrap.ps1 -Help
  Show this help message.
#>
[CmdletBinding()]
param(
  [Parameter()]
  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "..\src\hosts\windows\configuration.dsc.yaml"),

  [Parameter()]
  [string]$SecretsDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\src\secrets"),

  [Parameter()]
  [switch]$InstallDepsOnly,

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$VersionsFilePath = Join-Path -Path $PSScriptRoot -ChildPath "bootstrap-versions.env"

function Get-RequiredVersionSetting {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Settings,

    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  if (-not $Settings.Contains($Key) -or [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) {
    throw "Missing required setting '$Key' in $VersionsFilePath."
  }

  return [string]$Settings[$Key]
}

function Import-BootstrapVersions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
  )

  if (-not (Test-Path -Path $FilePath)) {
    throw "Bootstrap versions file not found: $FilePath"
  }

  $settings = [ordered]@{}

  foreach ($line in Get-Content -Path $FilePath) {
    $trimmed = $line.Trim()

    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed -notmatch "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$") {
      continue
    }

    $key = $Matches[1]
    $value = $Matches[2].Trim()

    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $settings[$key] = $value
  }

  return $settings
}

$BootstrapVersions = Import-BootstrapVersions -FilePath $VersionsFilePath

$BootstrapPackageVersions = [ordered]@{
  "Git.Git" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GIT_VERSION"
  "GnuPG.Gpg4win" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GPG4WIN_VERSION"
  "SecretsOPerationS.SOPS" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_SOPS_VERSION"
}

if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
  throw "winget is required but was not found in PATH."
}

function Ensure-WingetPackage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Id,

    [Parameter()]
    [string]$Version
  )

  $installArgs = @(
    "install"
    "--accept-package-agreements"
    "--accept-source-agreements"
    "--exact"
    "--id"
    $Id
    "--silent"
  )

  if ($Version) {
    $versionedArgs = @($installArgs + @("--version", $Version))
    & winget @versionedArgs

    if ($LASTEXITCODE -eq 0) {
      return
    }

    Write-Host "Requested version '$Version' for '$Id' not available. Falling back to latest." -ForegroundColor Yellow
  }

  & winget @installArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install package '$Id' with winget."
  }
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

foreach ($package in $BootstrapPackageVersions.GetEnumerator()) {
  Ensure-WingetPackage -Id $package.Key -Version $package.Value
}

if ($InstallDepsOnly) {
  Write-Host "Bootstrap dependencies installed. Skipping OS configuration and secrets provisioning." -ForegroundColor Green
  return
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
    throw "No GPG secret keys detected. Import your encryption subkey before bootstrap."
  }

  Write-Host "Decrypting with GPG keyring..." -ForegroundColor Cyan
  return (& $SopsExe @sopsArgs | ConvertFrom-Json)
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
