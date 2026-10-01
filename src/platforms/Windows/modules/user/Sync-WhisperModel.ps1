<#
.SYNOPSIS
    Converge the whisper.cpp ggml model weights under the nucleus user root.
.DESCRIPTION
    No package manager ships the whisper.cpp model weights: the Scoop manifest
    says so in its own `notes`, so this module downloads the revision-pinned
    file named in the lockfile's `whisper` section and re-hashes it against the
    pinned SRI value before moving it into place.

    A hash mismatch re-downloads rather than aborting. A 141 MB fetch is
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
    Sync-WhisperModel -RepoRoot $repoRoot -Enabled:$True

    Downloads any pinned model that is missing or does not match its hash, and
    leaves an already-correct model untouched.
.EXAMPLE
    Sync-WhisperModel -RepoRoot $repoRoot -Enabled:$False

    Removes the managed model files and leaves the models directory and anything
    else in it alone.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
#>
function Sync-WhisperModel {
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
    Write-NucleusError -CommandName 'whisper' "Sync-WhisperModel: lockfile not found at $lockfilePath"
    throw
  }
  $lockfile = Get-Content -LiteralPath $lockfilePath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $lockfile.ContainsKey('whisper')) {
    Write-NucleusError -CommandName 'whisper' 'Sync-WhisperModel: lockfile declares no whisper section, so there is nothing to pin'
    throw
  }

  $modelDir = Join-Path (Get-NucleusUserRoot) 'models'

  if (-not $Enabled) {
    foreach ($modelName in @($lockfile.whisper.Keys)) {
      $modelPath = Join-Path -Path $modelDir -ChildPath $modelName
      if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
        Remove-Item -LiteralPath $modelPath -Force
        Write-NucleusInfo -CommandName 'whisper' "removed $modelName"
      }
    }
    return
  }

  foreach ($modelName in @($lockfile.whisper.Keys)) {
    $pin = $lockfile.whisper[$modelName]
    $expectedSri = $pin['hash']
    $url = $pin['url']
    if ([string]::IsNullOrWhiteSpace($expectedSri) -or [string]::IsNullOrWhiteSpace($url)) {
      Write-NucleusError -CommandName 'whisper' "Sync-WhisperModel: lockfile entry '$modelName' must declare both url and hash"
      throw
    }

    $modelPath = Join-Path -Path $modelDir -ChildPath $modelName
    if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
      $deployedSri = Get-NucleusSriHash -Path $modelPath
      if ($deployedSri -eq $expectedSri) {
        Write-NucleusInfo -CommandName 'whisper' "$modelName already matches the pin; skipping download"
        continue
      }
      # Both digests, wanted first, matching the wording of the POSIX
      # `_lfe_check_whisper` probe. Reporting only the deployed one leaves the
      # operator to re-hash the lockfile by hand to tell a truncated file from a
      # stale pin.
      Write-NucleusInfo -CommandName 'whisper' "$modelName does not match the pin (expected $expectedSri, found $deployedSri); re-downloading"
    }

    if (-not (Test-Path -LiteralPath $modelDir -PathType Container)) {
      New-Item -ItemType Directory -Path $modelDir -Force > $null
    }

    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-whisper-$modelName"
    try {
      Write-NucleusInfo -CommandName 'whisper' "downloading $modelName"
      Invoke-WebRequest -Uri $url -OutFile $tempPath
      $downloadedSri = Get-NucleusSriHash -Path $tempPath
      if ($downloadedSri -ne $expectedSri) {
        Write-NucleusError -CommandName 'whisper' "Sync-WhisperModel: $modelName downloaded to $downloadedSri but the lockfile pins $expectedSri"
        throw
      }
      Move-Item -LiteralPath $tempPath -Destination $modelPath -Force
      Write-NucleusInfo -CommandName 'whisper' "$modelName deployed at $modelPath"
    }
    finally {
      if (Test-Path -LiteralPath $tempPath) {
        # check-suppress:suppression_doc: cleanup -- a leftover temp file must not fail a successful deployment, and a real failure is already reported by the caller's own error
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
