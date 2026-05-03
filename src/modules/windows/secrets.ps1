function Sync-NucleusSecretFile {
  <#
  .SYNOPSIS
    Decrypts one SOPS secret file and materializes its payloads on disk.

  .DESCRIPTION
    Calls Get-NucleusSecrets to decrypt $FilePath, then processes two
    optional payload fields:

    ssh_keys   — An array of {name, value} objects.  Each is written to
                 $HOME\.ssh\<name> using ASCII encoding (no BOM, no trailing
                 newline).  Files are only overwritten when the content has
                 actually changed to avoid unnecessary disk writes and
                 fingerprint updates.

    gpg_imports — An array of {name, value} objects.  Each value (an armored
                  GPG key block) is written to a temp file, imported with
                  `gpg --batch --import`, and the temp file is deleted.  Import
                  output is suppressed; errors surface as exceptions.

    $HOME\.ssh is created if it does not already exist.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to the SSH host private key used as the age decryption key.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Sync-NucleusSecretFile -FilePath '.\personal.yml' -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' -SopsExe 'sops.exe'
  #>
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

  $secretFileInfo = Get-Item -Path $FilePath
  $sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }

  Write-Host "Processing secrets from: $($secretFileInfo.Name)" -ForegroundColor Cyan
  $jsonSecrets = Get-NucleusSecrets -FilePath $secretFileInfo.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -SopsExe $SopsExe

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
        & $GpgExe --batch --import "$tempPath" | Out-Null
        Write-Host "  Imported GPG material: $($gpgKey.name)" -ForegroundColor Cyan
      }
      finally {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Invoke-NucleusJitSecretMaterialization {
  <#
  .SYNOPSIS
    Materializes a specific subset of named secret files on demand (JIT).

  .DESCRIPTION
    Designed for modules that need exactly one or two secrets rather than the
    full batch sync.  For each name in $SecretNames, the function resolves the
    corresponding .yml file under $SecretsDir (appending .yml if omitted) and
    calls Sync-NucleusSecretFile.  Throws immediately if a requested secret
    file does not exist.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

  .PARAMETER SecretNames
    Names of the secret files to materialize.  The .yml extension is optional;
    it is appended automatically if not present.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to the SSH host private key used as the age decryption key.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Invoke-NucleusJitSecretMaterialization -SecretsDir '.\secrets' `
        -SecretNames @('personal', 'work') `
        -GpgExe 'gpg.exe' -HostKeyPath '...\ssh_host_ed25519_key' -SopsExe 'sops.exe'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string[]]$SecretNames,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  foreach ($secretName in $SecretNames) {
    $normalizedSecretFile = if ($secretName.EndsWith(".yml")) { $secretName } else { "$secretName.yml" }
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $normalizedSecretFile

    if (-not (Test-Path -Path $secretPath)) {
      throw "Requested JIT secret file was not found: $secretPath"
    }

    Sync-NucleusSecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -SopsExe $SopsExe
  }
}

function Sync-NucleusSecrets {
  <#
  .SYNOPSIS
    Batch-syncs all SOPS-encrypted secret files found in $SecretsDir.

  .DESCRIPTION
    Enumerates all *.yml files in $SecretsDir (sorted alphabetically) and calls
    Sync-NucleusSecretFile for each one.  This is the top-level entry point
    used by apply.ps1 for a full secrets pass.

    No-op (with a warning) when $SecretsDir does not exist or contains no .yml
    files, so the function is safe to call even on machines where secrets have
    not been provisioned yet.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to the SSH host private key used as the age decryption key.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Sync-NucleusSecrets -SecretsDir '.\secrets' -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' -SopsExe 'sops.exe'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $secretFiles = @()
  if (-not (Test-Path -Path $SecretsDir)) {
    Write-Host "No secrets directory found at $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
    return
  }

  $secretFiles = @(Get-ChildItem -Path $SecretsDir -Filter "*.yml" | Sort-Object Name)
  if ($secretFiles.Count -eq 0) {
    Write-Host "No .yml secret files found in $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
    return
  }

  foreach ($secretFile in $secretFiles) {
    Sync-NucleusSecretFile -FilePath $secretFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -SopsExe $SopsExe
  }
}
