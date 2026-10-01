# PsGalleryPin.ps1 - PSGallery nupkg pin helpers for Windows tooling.
#
# lockfile.json's `psgallery` entries are a plain version string or a
# {version, hash} object whose `hash` is the nupkg SHA256 in SRI form. PSGallery has
# no release-age feature, so the version pin plus that hash is the mitigation.
# `nucleus-update lockfile` dot-sources this file to recompute the hash on a version
# bump; a hash is never carried over from the previous version.

# Compute the SRI-form SHA256 ('sha256-<base64>') of a file.
function Get-NucleusSriHash {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      return 'sha256-' + [System.Convert]::ToBase64String($sha.ComputeHash($stream))
    } finally {
      $sha.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

# Fetch one PSGallery module nupkg and return its SRI-form SHA256. Empty means the
# download failed, so the caller leaves the lockfile entry unchanged.
function Get-PsgalleryNupkgHash {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ModuleName,
    [Parameter(Mandatory)]
    [string]$Version
  )

  $nupkgPath = Join-Path ([System.IO.Path]::GetTempPath()) "nucleus-psgallery-$ModuleName.$Version.nupkg"
  try {
    # check-suppress:suppression_doc: a failed download must yield the documented empty result, which the caller reports as an unverified hash.
    Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2/package/$ModuleName/$Version" -OutFile $nupkgPath -ErrorAction Stop
    return Get-NucleusSriHash -Path $nupkgPath
  } catch {
    return ''
  } finally {
    if (Test-Path -LiteralPath $nupkgPath) {
      # check-suppress:suppression_doc: best-effort temp cleanup; an already-removed file is not an error.
      Remove-Item -LiteralPath $nupkgPath -Force -ErrorAction SilentlyContinue
    }
  }
}
