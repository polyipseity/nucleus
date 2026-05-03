function Sync-NucleusSecrets {
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

  $sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }

  foreach ($secretFile in $secretFiles) {
    Write-Host "Processing secrets from: $($secretFile.Name)" -ForegroundColor Cyan
    $jsonSecrets = Get-NucleusSecrets -FilePath $secretFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -SopsExe $SopsExe

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
}
