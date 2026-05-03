function Resolve-NucleusExecutable {
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

function Get-NucleusDecryptedBlob {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output", $OutputPath, $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      & $SopsExe @sopsArgs
      if ($LASTEXITCODE -eq 0) {
        return
      }

      Write-Host "Host-key decryption failed for '$FilePath'. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  if (-not $secretKeyInfo -or -not ($secretKeyInfo -match "^(sec|ssb):")) {
    throw "No GPG secret keys detected. Import your encryption subkey before decrypting binary assets."
  }

  & $SopsExe @sopsArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to decrypt blob '$FilePath'."
  }
}
