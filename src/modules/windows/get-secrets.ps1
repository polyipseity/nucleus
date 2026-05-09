# modules/windows/get-secrets.ps1 — Structured secret decryption helper.
#
# Decrypts SOPS YAML and returns JSON-decoded secret objects using the shared
# machine-ssh -> gpg -> primary-ssh fallback chain.

function Get-Secrets {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted YAML file and returns its contents as a
    PSCustomObject.

  .DESCRIPTION
    Attempts decryption in priority order:
      1. Machine SSH key (age recipient derived from this machine's SSH host key).
         The key path is passed via the SOPS_AGE_SSH_PRIVATE_KEY_FILE env var
         and cleared in a `finally` block so it is never left in the environment.
      2. GPG keyring.
      3. Primary personal SSH key (age recipient derived from
         ssh_personal_<user>.pub).

    The decrypted payload is parsed from JSON and returned as a PowerShell
    object so callers can access named fields with dot notation.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file to decrypt.

  .PARAMETER GpgExe
    Absolute path to the gpg executable (used for both GPG-path decryption
    and pre-flight key detection).

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.
    When the file does not exist, machine-key decryption is skipped and GPG is
    tried.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [PSCustomObject]  Decrypted secret data as a structured object.

  .EXAMPLE
    $secrets = Get-NucleusSecrets -FilePath '.\secrets.yml' -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
        -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe'
    $secrets.ssh_keys
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output-format", "json", $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    Write-Output "$($PSStyle.Foreground.Green)Found machine SSH key. Trying machine-key decryption first...$($PSStyle.Reset)"
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Output "$($PSStyle.Foreground.Yellow)Machine-key decryption failed. Falling back to GPG keyring...$($PSStyle.Reset)"
    }
    finally {
      # SilentlyContinue in a finally block prevents a cleanup failure from
      # masking the original exception from the try block above.
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons
  $hasGpgSecretKeys = ($secretKeyInfo -and ($secretKeyInfo -match "^(sec|ssb):"))
  if ($hasGpgSecretKeys) {
    try {
      Write-Output "$($PSStyle.Foreground.Cyan)Decrypting with GPG keyring...$($PSStyle.Reset)"
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Output "$($PSStyle.Foreground.Yellow)GPG decryption failed. Trying primary SSH key fallback...$($PSStyle.Reset)"
    }
  }
  else {
    Write-Output "$($PSStyle.Foreground.Yellow)No GPG secret keys detected. Trying primary SSH key fallback...$($PSStyle.Reset)"
  }

  if (Test-Path -Path $PrimarySshKeyPath) {
    Write-Output "$($PSStyle.Foreground.Green)Found primary SSH key. Trying primary-ssh decryption...$($PSStyle.Reset)"
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      throw "Primary-ssh decryption failed for '$FilePath' after machine-key and GPG attempts."
    }
    finally {
      # SilentlyContinue in a finally block prevents a cleanup failure from
      # masking the original exception from the try block above.
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  throw "Unable to decrypt '$FilePath'. Machine SSH key, GPG keyring, and primary SSH key were unavailable or failed."
}
