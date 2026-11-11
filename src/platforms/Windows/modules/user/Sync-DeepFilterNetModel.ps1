<#
.SYNOPSIS
    Converge the DeepFilterNet3 ONNX model weights under the nucleus user root.
.DESCRIPTION
    No package manager ships the DeepFilterNet3 ONNX model weights, so this
    module downloads the revision-pinned file named in the lockfile's
    `deepfilternet` section and re-hashes it against the pinned SRI value before
    moving it into place.

    A hash mismatch re-downloads rather than aborting. A download is
    recoverable by retrying, and refusing to converge would leave the capability
    dead for a transient network failure or a truncated write; this matches the
    POSIX activation, which rewrites the deployed copy whenever its digest
    differs from the store source.

    The download lands on a temp file first, so an interrupted transfer can
    never be mistaken for a good model. The final file appears only after its
    digest has been verified.
.PARAMETER RepoRoot
    Repository root. apply.ps1 resolves it from $PSScriptRoot and passes it
    explicitly.
.PARAMETER Enabled
    Converge the model when true; remove the managed copies when false.
.OUTPUTS
    None.
.EXAMPLE
    Sync-DeepFilterNetModel -RepoRoot $repoRoot -Enabled:$True

    Downloads any pinned model that is missing or does not match its hash, and
    leaves an already-correct model untouched.
.EXAMPLE
    Sync-DeepFilterNetModel -RepoRoot $repoRoot -Enabled:$False

    Removes the managed model files and leaves the models directory and anything
    else in it alone.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
#>
function Sync-DeepFilterNetModel {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\ManagedPaths.ps1')
  . (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\PsGalleryPin.ps1')

  $lockfilePath = Join-Path -Path $RepoRoot -ChildPath 'src\lockfiles\lockfile.json'
  if (-not (Test-Path -LiteralPath $lockfilePath -PathType Leaf)) {
    Write-NucleusError -CommandName 'deepfilternet' "Sync-DeepFilterNetModel: lockfile not found at $lockfilePath"
    throw
  }
  $lockfile = Get-Content -LiteralPath $lockfilePath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $lockfile.ContainsKey('deepfilternet')) {
    Write-NucleusError -CommandName 'deepfilternet' 'Sync-DeepFilterNetModel: lockfile declares no deepfilternet section, so there is nothing to pin'
    throw
  }

  $modelDir = Join-Path (Get-NucleusUserRoot) 'models'

  if (-not $Enabled) {
    foreach ($modelName in @($lockfile.deepfilternet.Keys)) {
      $modelPath = Join-Path -Path $modelDir -ChildPath $modelName
      if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
        Remove-Item -LiteralPath $modelPath -Force
        Write-NucleusInfo -CommandName 'deepfilternet' "removed $modelName"
      }
    }
    return
  }

  foreach ($modelName in @($lockfile.deepfilternet.Keys)) {
    $pin = $lockfile.deepfilternet[$modelName]
    $expectedSri = $pin['hash']
    $url = $pin['url']
    if ([string]::IsNullOrWhiteSpace($expectedSri) -or [string]::IsNullOrWhiteSpace($url)) {
      Write-NucleusError -CommandName 'deepfilternet' "Sync-DeepFilterNetModel: lockfile entry '$modelName' must declare both url and hash"
      throw
    }

    $modelPath = Join-Path -Path $modelDir -ChildPath $modelName
    if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
      $deployedSri = Get-NucleusSriHash -Path $modelPath
      if ($deployedSri -eq $expectedSri) {
        Write-NucleusInfo -CommandName 'deepfilternet' "$modelName already matches the pin; skipping download"
        continue
      }
      # Both digests, wanted first, matching the wording of the POSIX probe.
      Write-NucleusInfo -CommandName 'deepfilternet' "$modelName does not match the pin (expected $expectedSri, found $deployedSri); re-downloading"
    }

    if (-not (Test-Path -LiteralPath $modelDir -PathType Container)) {
      New-Item -ItemType Directory -Path $modelDir -Force > $null
    }

    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-deepfilternet-$modelName"
    try {
      Write-NucleusInfo -CommandName 'deepfilternet' "downloading $modelName"
      Invoke-WebRequest -Uri $url -OutFile $tempPath
      $downloadedSri = Get-NucleusSriHash -Path $tempPath
      if ($downloadedSri -ne $expectedSri) {
        Write-NucleusError -CommandName 'deepfilternet' "Sync-DeepFilterNetModel: $modelName downloaded to $downloadedSri but the lockfile pins $expectedSri"
        throw
      }
      Move-Item -LiteralPath $tempPath -Destination $modelPath -Force
      Write-NucleusInfo -CommandName 'deepfilternet' "$modelName deployed at $modelPath"
    }
    finally {
      if (Test-Path -LiteralPath $tempPath) {
        # check-suppress:suppression_doc: cleanup -- a leftover temp file must not fail a successful deployment, and a real failure is already reported by the caller's own error
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
