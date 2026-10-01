<#
.SYNOPSIS
  Runs the consolidated Windows update workflow.
.DESCRIPTION
  -Action all (default) runs flake input updates, the SOPS rewrap, and the
  lockfile bump. -Action lockfile runs only the lockfile step. The repository
  root comes from NUCLEUS_REPO_ROOT, falling back to the parent of the script
  directory.
.PARAMETER Sections
  Comma-separated section names (default: all). Legacy bare tokens
  (nixos-iso, tart-images) and the cargo alias normalize to their canonical
  dotted form; unknown tokens are rejected.
.PARAMETER Verify
  Check for updates without writing; exit 1 if changes would be made.
.PARAMETER VerifyInstalled
  Verify installed tool versions against the pins; exit 1 on drift. Never writes.
.PARAMETER ListSections
  Print valid section names, one per line, and exit 0.
.NOTES
  Environment: NUCLEUS_NO_FLAKE, NUCLEUS_NO_SOPS, NUCLEUS_REPO_ROOT.
#>
[CmdletBinding()]
param(
  [ValidateSet('all', 'lockfile')]
  [string]$Action = 'all',
  [switch]$NoFlake = $(if ($env:NUCLEUS_NO_FLAKE -eq 'true') { $true } else { $false }),
  [switch]$NoSops = $(if ($env:NUCLEUS_NO_SOPS -eq 'true') { $true } else { $false }),
  [Alias("h")]
  [switch]$Help,
  [string]$Sections = '',
  [switch]$Verify,
  [switch]$VerifyInstalled,
  [switch]$ListSections
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path }

function Invoke-UpdateAll {
  [CmdletBinding()]
  param(
    [switch]$NoFlake,
    [switch]$NoSops
  )

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not $NoFlake -and (Get-Command -Name 'nix.exe' -ErrorAction SilentlyContinue)) {
    $flakeOutput = & nix.exe --option warn-dirty false flake update --flake (Join-Path -Path $repoRoot -ChildPath 'src') 2>&1
    if ($LASTEXITCODE -ne 0) {
      $joined = ($flakeOutput | Out-String)
      if ($joined -match 'API rate limit exceeded|unable to download|HTTP error 403') {
        Write-NucleusWarning 'flake update skipped due to transient fetch/rate-limit error.'
      }
      else {
        throw 'nucleus: nix flake update failed.'
      }
    }
  }

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not $NoSops -and -not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: sops.exe is required for update secret rewrap step.'
  }

  $sopsConfig = Join-Path -Path $repoRoot -ChildPath '.sops.yaml'

  if (-not $NoSops) {
    $usersSecretsDir = Join-Path -Path $repoRoot -ChildPath 'src\secrets\users'
    if (Test-Path -Path $usersSecretsDir) {
      Get-ChildItem -Path $usersSecretsDir -Filter '*.yml' -File | ForEach-Object {
        & sops --config $sopsConfig updatekeys --yes $_.FullName
        if ($LASTEXITCODE -ne 0) {
          throw "nucleus: failed to rewrap per-user secret file '$($_.FullName)'."
        }
      }
    }
    # check-suppress:suppression_doc: probe -- no encrypted wallpaper blobs may exist; empty result handled.
    $wallpaperList = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'src\users') -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
    foreach ($encryptedWallpaper in $wallpaperList) {
      & sops --config $sopsConfig updatekeys --yes $encryptedWallpaper.FullName
      if ($LASTEXITCODE -ne 0) {
        throw "nucleus: failed to rewrap wallpaper blob '$($encryptedWallpaper.FullName)'."
      }
    }
  }
}

function Invoke-LockfileBump {
  [CmdletBinding()]
  param(
    [string]$Sections = '',
    [switch]$Verify,
    [switch]$VerifyInstalled,
    [switch]$ListSections
  )

  . (Join-Path $repoRoot 'src/platforms/Windows/modules/lib/JsonSort.ps1')

  . (Join-Path $repoRoot 'src/platforms/Windows/modules/lib/PsGalleryPin.ps1')

  $validSectionsCsv = 'bun,cargo,cargo-binstall,cursor,pi,psgallery,rustup,scoop,source-builds,uv,version,vm-setup,vm-setup.nixos-iso,vm-setup.tart-images,vscode,whisper,winget,suggestions.cursor,suggestions.homebrew,suggestions.homebrew.masApps,suggestions.ollama,suggestions.opencode,suggestions.vscode,suggestions.vm-setup.windows'

  if ($ListSections) {
    foreach ($s in ($validSectionsCsv -split ',')) {
      Write-NucleusInfo $s
    }
    return
  }

  $lockfileRel = 'src/lockfiles/lockfile.json'
  $lockfileAbs = Join-Path -Path $repoRoot -ChildPath $lockfileRel

  if (-not (Test-Path -Path $lockfileAbs)) {
    Write-NucleusError -CommandName update -Message "lockfile not found at $lockfileAbs" -ErrorAction Continue
    exit 1
  }

  $sectionTokens = @()
  if (-not [string]::IsNullOrEmpty($Sections)) {
    foreach ($tok in ($Sections -split ',')) {
      $tok = $tok.Trim()
      if ([string]::IsNullOrEmpty($tok)) { continue }
      switch ($tok) {
        'nixos-iso' { $tok = 'vm-setup.nixos-iso' }
        'tart-images' { $tok = 'vm-setup.tart-images' }
        'cargo' { $tok = 'cargo-binstall' }
      }
      if (",$validSectionsCsv," -notmatch ",$tok,") {
        Write-NucleusError -CommandName update -Message "unknown section '$tok' (valid: $validSectionsCsv)" -ErrorAction Continue
        exit 1
      }
      $sectionTokens += $tok
    }
  }

  foreach ($tok in $sectionTokens) {
    if (",source-builds,cursor,vscode,whisper,suggestions.homebrew.masApps,suggestions.opencode,suggestions.vm-setup.windows,version," -match ",$tok,") {
      Write-NucleusWarning "section '$tok' has no updater — kept manual"
    }
  }

  function Write-Update {
    param([string]$Section, [string]$Key, [string]$OldValue, [string]$NewValue)
    $script:changed = $true
    Write-NucleusInfo "updating ${Section}.${Key} from ${OldValue} to ${NewValue}"
  }

  function Test-SectionEnabled {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Sections)) { return $true }
    foreach ($token in $sectionTokens) {
      if ($Name -eq $token -or $Name.StartsWith("$token.")) { return $true }
    }
    return $false
  }

  function Test-SuggestionsEnabled {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Sections)) { return $true }
    foreach ($token in $sectionTokens) {
      if ($token.StartsWith('suggestions') -and ($Name -eq $token -or $Name.StartsWith("$token."))) { return $true }
    }
    return $false
  }

  function ConvertTo-Hashtable {
    param([object]$InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
      $ht = @{}
      $InputObject.PSObject.Properties | ForEach-Object {
        $ht[$_.Name] = ConvertTo-Hashtable $_.Value
      }
      return $ht
    } elseif ($InputObject -is [object[]]) {
      $list = @()
      foreach ($item in $InputObject) {
        $list += ConvertTo-Hashtable $item
      }
      return ,$list  # comma preserves array
    } else {
      return $InputObject
    }
  }

  $rawJson = Get-Content -Path $lockfileAbs -Raw -Encoding UTF8
  $lockfile = $rawJson | ConvertFrom-Json -Depth 32
  $ht = ConvertTo-Hashtable $lockfile

  if ($VerifyInstalled) {
    . (Join-Path $repoRoot 'src/scripts/checks/lockfile-enforcement-lib.ps1')
    $drift = Invoke-LockfileEnforcement `
      -Lockfile $ht `
      -InfoFn { param($m) Write-NucleusInfo $m } `
      -WarnFn { param($m) Write-NucleusWarning $m } `
      -ErrorFn { param($m) Write-NucleusError -CommandName update -Message $m -ErrorAction Continue }
    exit $drift
  }

  # least one section produced a change (set by Write-Update). Stamping before
  # the queries would make every run rewrite the file (timestamp churn).
  $changed = $false

  # winget — winget show --id <id>
  if (Test-SectionEnabled 'winget') {
    if (Get-Command -Name 'winget' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('winget') -and $ht['winget'] -is [hashtable]) {
        # Snapshot the keys: assigning a value below invalidates the live
        # KeyCollection enumerator on .NET Core ('Collection was modified').
        foreach ($key in @($ht['winget'].Keys)) {
          $old = $ht['winget'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & winget show --id $key 2>$null | Select-String -Pattern '^Version '
          if ($result) {
            $new = ($result -split ':\s*', 2)[-1].Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'winget' -Key $key -OldValue $old -NewValue $new
              $ht['winget'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'winget not found — skipping winget section'
    }
  }

  # scoop — scoop info <pkg>
  if (Test-SectionEnabled 'scoop') {
    if (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('scoop') -and $ht['scoop'] -is [hashtable]) {
        foreach ($key in @($ht['scoop'].Keys)) {
          $old = $ht['scoop'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & scoop info $key 2>$null | Select-String -Pattern '^Version '
          if ($result) {
            $new = ($result -split ':\s*', 2)[-1].Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'scoop' -Key $key -OldValue $old -NewValue $new
              $ht['scoop'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'scoop not found — skipping scoop section'
    }
  }

  # cargo-binstall — crates.io API
  if (Test-SectionEnabled 'cargo-binstall') {
    if ($ht.ContainsKey('cargo-binstall') -and $ht['cargo-binstall'] -is [hashtable]) {
      foreach ($key in @($ht['cargo-binstall'].Keys)) {
        if ($ht['cargo-binstall'][$key] -is [hashtable]) {
          continue  # object entry — no version query applies
        }
        $old = $ht['cargo-binstall'][$key]
        $new = $null
        try {
          # check-suppress:suppression_doc: probe -- crate may not exist or network unavailable; cargo search is the fallback below
          $resp = Invoke-RestMethod -Uri "https://crates.io/api/v1/crates/$key" -Headers @{ 'User-Agent' = 'nucleus-update-lockfile' }
          if ($resp.crate.max_stable_version) {
            $new = $resp.crate.max_stable_version
          } elseif ($resp.versions -and $resp.versions.Count -gt 0) {
            $new = $resp.versions[0].num
          }
        } catch {
          $new = $null  # check-suppress:suppression_doc: API failure — cargo search below is the only other version source
        }
        if ([string]::IsNullOrEmpty($new)) {
          # check-suppress:suppression_doc: probe -- crate may not exist; stderr suppressed for clean output.
          $searchOutput = & cargo search --limit 1 $key 2>$null
          if ($searchOutput) {
            foreach ($line in $searchOutput) {
              $match = [regex]::Match($line.Trim(), '^[^\s=]+\s*=\s*"([^"]+)"')
              if ($match.Success) {
                $new = $match.Groups[1].Value.Trim()
                break
              }
            }
          }
        }
        if ([string]::IsNullOrEmpty($new)) {
          Write-NucleusWarning "cargo-binstall.${key}: no version source (crates.io API and cargo search both failed)"
          continue
        }
        if ($new -ne $old) {
          Write-Update -Section 'cargo-binstall' -Key $key -OldValue $old -NewValue $new
          $ht['cargo-binstall'][$key] = $new
        }
      }
    }
  }

  # bun — npm registry API (curl)
  if (Test-SectionEnabled 'bun') {
    if (Get-Command -Name 'curl' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('bun') -and $ht['bun'] -is [hashtable]) {
        foreach ($key in @($ht['bun'].Keys)) {
          $old = $ht['bun'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & curl -fsSL "https://registry.npmjs.org/$key/latest" 2>$null
          if ($result) {
            $parsed = $result | ConvertFrom-Json
            $new = $parsed.version.Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'bun' -Key $key -OldValue $old -NewValue $new
              $ht['bun'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'curl: command not found — skipping bun section'
    }
  }

  if (Test-SectionEnabled 'pi') {
    if (Get-Command -Name 'curl' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('pi') -and $ht['pi'] -is [hashtable]) {
        $ageSeconds = if ($env:MINIMUM_RELEASE_AGE) { [int]$env:MINIMUM_RELEASE_AGE } else { 432000 }
        foreach ($key in @($ht['pi'].Keys)) {
          $old = $ht['pi'][$key]
          if ($old -isnot [string]) { continue }
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & curl -fsSL "https://registry.npmjs.org/$key" 2>$null
          if ($result) {
            $parsed = $result | ConvertFrom-Json
            $versions = @($parsed.PSObject.Properties |
              Where-Object { $_.Name -match '^[0-9]' -and $parsed.time.$($_.Name) } |
              ForEach-Object {
                $pubEpoch = [int][double]::Parse((Get-Date ([datetime]::Parse($parsed.time.$($_.Name)).ToUniversalTime()) -UFormat '%s'))
                $age = [int][double]::Parse((Get-Date -UFormat '%s')) - $pubEpoch
                if ($age -ge $ageSeconds) { [pscustomobject]@{ Version = $_.Name; Age = $age } }
              })
            $new = ($versions | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1).Version
            if ([string]::IsNullOrEmpty($new)) {
              Write-NucleusWarning "pi.$key`: no version older than the minimum release age -- keeping $old"
            } elseif ($new -ne $old) {
              Write-Update -Section 'pi' -Key $key -OldValue $old -NewValue $new
              $ht['pi'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'curl: command not found -- skipping pi section'
    }
  }

  if (Test-SectionEnabled 'uv') {
    if (Get-Command -Name 'uv' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      # check-suppress:suppression_doc: probe -- uv may not be installed; stderr suppressed for clean output.
      $uvOutput = & uv tool list 2>$null
      if ($uvOutput) {
        $uvInstalled = @{}
        foreach ($line in $uvOutput) {
          $line = $line.Trim()
          if ([string]::IsNullOrEmpty($line)) { continue }
          # Strip leading dashes/bullets
          $line = $line -replace '^-\s+', ''
          if ($line -match '@') {
            $parts = $line -split '@', 2
            $pkg = $parts[0].Trim()
            $ver = $parts[1].Trim()
          } else {
            # "package v1.0.0"
            $parts = $line -split '\s+', 2
            $pkg = $parts[0].Trim()
            $ver = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
          }
          $ver = $ver -replace '^v', ''
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $uvInstalled[$pkg] = $ver
          }
        }

        if ($ht.ContainsKey('uv') -and $ht['uv'] -is [hashtable]) {
          foreach ($key in @($ht['uv'].Keys)) {
            if ($ht['uv'][$key] -is [hashtable]) {
              continue  # VCS hash-pin entry — no CLI query can update the rev
            }
            $old = $ht['uv'][$key]
            if ($uvInstalled.ContainsKey($key)) {
              $new = $uvInstalled[$key]
              if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
                Write-Update -Section 'uv' -Key $key -OldValue $old -NewValue $new
                $ht['uv'][$key] = $new
              }
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'uv not found — skipping uv section'
    }
  }

  # rustup — rustc +<channel> --version
  if (Test-SectionEnabled 'rustup') {
    if (Get-Command -Name 'rustup' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      # check-suppress:suppression_doc: probe -- rustup may not be installed; stderr suppressed for clean output.
      $toolchains = & rustup toolchain list 2>$null
      $toolchainSet = @{}
      if ($toolchains) {
        foreach ($tc in $toolchains) {
          $channel = ($tc -split '-', 2)[0].Trim()
          if (-not [string]::IsNullOrEmpty($channel)) {
            $toolchainSet[$channel] = $true
          }
        }
      }

      if ($ht.ContainsKey('rustup') -and $ht['rustup'] -is [hashtable]) {
        foreach ($key in @($ht['rustup'].Keys)) {
          $old = $ht['rustup'][$key]
          if ($toolchainSet.ContainsKey($key)) {
            # check-suppress:suppression_doc: probe -- toolchain may not be installed; stderr suppressed for clean output.
            $versionOutput = & rustc "+$key" --version 2>$null
            if ($versionOutput) {
              if ($key -eq 'nightly' -or $key -match '^nightly-\d{4}-\d{2}-\d{2}$') {
                $match = [regex]::Match($versionOutput, 'nightly-\d{4}-\d{2}-\d{2}')
              } else {
                $match = [regex]::Match($versionOutput, '\d+\.\d+\.\d+')
              }
              if ($match.Success) {
                $new = $match.Value
                if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
                  Write-Update -Section 'rustup' -Key $key -OldValue $old -NewValue $new
                  $ht['rustup'][$key] = $new
                }
              }
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'rustup not found — skipping rustup section'
    }
  }

  if (Test-SectionEnabled 'psgallery') {
    if (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('psgallery') -and $ht['psgallery'] -is [hashtable]) {
        foreach ($key in @($ht['psgallery'].Keys)) {
          $pin = $ht['psgallery'][$key]
          $isObjectPin = $pin -is [hashtable]
          $old = if ($isObjectPin) { $pin['version'] } else { $pin }
          # check-suppress:suppression_doc: probe -- module may not exist in PSGallery; stderr suppressed for clean output.
          $result = & pwsh -NoProfile -Command "Find-Module -Name '$key' | Select-Object -ExpandProperty Version" 2>$null
          if ($result) {
            $new = $result.Trim()
            # WHY: Find-Module renders its warnings on stdout, so an unreachable
            # PSGallery yields escape-coded noise instead of a version. Never
            # write that through as a pin — leave the entry unchanged.
            if (-not [string]::IsNullOrEmpty($new) -and $new -notmatch '^[0-9A-Za-z.+-]+$') {
              Write-NucleusWarning "psgallery.$key`: could not resolve a version — leaving the entry unchanged"
              continue
            }
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              if ($isObjectPin) {
                $newHash = Get-PsgalleryNupkgHash -ModuleName $key -Version $new
                if ([string]::IsNullOrEmpty($newHash)) {
                  Write-NucleusWarning "psgallery.$key`: could not fetch the nupkg hash for $new — leaving the entry unchanged"
                  continue
                }
                Write-Update -Section 'psgallery' -Key $key -OldValue $old -NewValue $new
                $ht['psgallery'][$key] = @{ hash = $newHash; version = $new }
              } else {
                Write-Update -Section 'psgallery' -Key $key -OldValue $old -NewValue $new
                $ht['psgallery'][$key] = $new
              }
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'pwsh not found — skipping psgallery section'
    }
  }

  if (Test-SuggestionsEnabled 'suggestions.cursor') {
    $cursorOutput = $null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command -Name 'cursor' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $cursorOutput = & cursor --list-extensions --show-versions 2>$null
    } else {
      Write-NucleusWarning 'cursor not found — skipping suggestions.cursor section'
    }

    if ($cursorOutput) {
      $cursorExts = @{
      }
      foreach ($line in $cursorOutput) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        $atIdx = $line.LastIndexOf('@')
        if ($atIdx -ge 0) {
          $pkg = $line.Substring(0, $atIdx)
          $ver = $line.Substring($atIdx + 1)
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $cursorExts[$pkg] = $ver
          }
        }
      }

      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('cursor') -and $ht['suggestions']['cursor'] -is [hashtable]) {
        foreach ($key in @($ht['suggestions']['cursor'].Keys)) {
          $old = $ht['suggestions']['cursor'][$key]
          if ($cursorExts.ContainsKey($key)) {
            $new = $cursorExts[$key]
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'suggestions.cursor' -Key $key -OldValue $old -NewValue $new
              $ht['suggestions']['cursor'][$key] = $new
            }
          }
        }
      }
    }
  }

  if (Test-SuggestionsEnabled 'suggestions.cursor') {
    $cursorOutput = $null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command -Name 'cursor' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $cursorOutput = & cursor --list-extensions --show-versions 2>$null
    } else {
      Write-NucleusWarning 'cursor not found — skipping suggestions.cursor section'
    }

    if ($cursorOutput) {
      $cursorExts = @{}
      foreach ($line in $cursorOutput) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        $atIdx = $line.LastIndexOf('@')
        if ($atIdx -ge 0) {
          $pkg = $line.Substring(0, $atIdx)
          $ver = $line.Substring($atIdx + 1)
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $cursorExts[$pkg] = $ver
          }
        }
      }

      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('cursor') -and $ht['suggestions']['cursor'] -is [hashtable]) {
        foreach ($key in @($ht['suggestions']['cursor'].Keys)) {
          $old = $ht['suggestions']['cursor'][$key]
          if ($cursorExts.ContainsKey($key)) {
            $new = $cursorExts[$key]
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'suggestions.cursor' -Key $key -OldValue $old -NewValue $new
              $ht['suggestions']['cursor'][$key] = $new
            }
          }
        }
      }
    }
  }

  if (Test-SuggestionsEnabled 'suggestions.vscode') {
    $vscodeOutput = $null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command -Name 'code' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $vscodeOutput = & code --list-extensions --show-versions 2>$null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    } elseif (Get-Command -Name 'code-insiders' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $vscodeOutput = & code-insiders --list-extensions --show-versions 2>$null
    } else {
      Write-NucleusWarning 'code/code-insiders not found — skipping suggestions.vscode section'
    }

    if ($vscodeOutput) {
      $vscodeExts = @{}
      foreach ($line in $vscodeOutput) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        $atIdx = $line.LastIndexOf('@')
        if ($atIdx -ge 0) {
          $pkg = $line.Substring(0, $atIdx)
          $ver = $line.Substring($atIdx + 1)
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $vscodeExts[$pkg] = $ver
          }
        }
      }

      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('vscode') -and $ht['suggestions']['vscode'] -is [hashtable]) {
        foreach ($key in @($ht['suggestions']['vscode'].Keys)) {
          $old = $ht['suggestions']['vscode'][$key]
          if ($vscodeExts.ContainsKey($key)) {
            $new = $vscodeExts[$key]
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'suggestions.vscode' -Key $key -OldValue $old -NewValue $new
              $ht['suggestions']['vscode'][$key] = $new
            }
          }
        }
      }
    }
  }

  if (Test-SuggestionsEnabled 'suggestions.ollama') {
    # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
    # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
    if (Get-Command -Name 'ollama' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('ollama') -and $ht['suggestions']['ollama'] -is [hashtable]) {
        foreach ($hostName in $ht['suggestions']['ollama'].Keys) {
          $models = $ht['suggestions']['ollama'][$hostName]
          if ($models -isnot [System.Collections.IList]) { continue }

          for ($idx = 0; $idx -lt $models.Count; $idx++) {
            $entry = $models[$idx]
            $name = $entry['name']
            $tag = $entry['tag']
            if ([string]::IsNullOrEmpty($name) -or [string]::IsNullOrEmpty($tag)) { continue }

            $hasDigest = $entry.ContainsKey('digest')
            $oldDigest = if ($hasDigest) { $entry['digest'] } else { $null }

            $ollamaHostAddr = if ($env:NUCLEUS_OLLAMA_HOST) { $env:NUCLEUS_OLLAMA_HOST } else { # check-suppress:suppression_doc: probe -- services.json may not exist yet; falls back to default localhost port
            $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json; if ($svc.ollama.network.default) { "$($svc.ollama.network.default.host):$($svc.ollama.network.default.port)" } else { '127.0.0.1:11434' } }
            try {
              $oldOllamaHost = $env:OLLAMA_HOST
              $env:OLLAMA_HOST = $ollamaHostAddr
              # check-suppress:suppression_doc: probe -- model may not exist in registry; stderr suppressed for clean output.
              $ollamaInfo = & ollama show "${name}:${tag}" --format json 2>$null
              $env:OLLAMA_HOST = $oldOllamaHost
              if ($ollamaInfo) {
                $ollamaJson = $ollamaInfo | Out-String | ConvertFrom-Json -Depth 10
                $newDigest = $ollamaJson.digest
                if (-not [string]::IsNullOrEmpty($newDigest) -and $newDigest -ne $oldDigest) {
                  Write-Update -Section "ollama ($hostName)" -Key "${name}:${tag}" -OldValue ($oldDigest ?? 'none') -NewValue $newDigest
                  $entry['digest'] = $newDigest
                }
              }
            } catch {
              Write-NucleusWarning "ollama show failed for ${name}:${tag}; keeping existing digest"
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'ollama not found — skipping ollama section'
    }
  }

  if (Test-SectionEnabled 'vm-setup.nixos-iso') {
    if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('nixos-iso') -and $ht['vm-setup']['nixos-iso'] -is [hashtable]) {
      foreach ($arch in @($ht['vm-setup']['nixos-iso'].Keys)) {
        $entry = $ht['vm-setup']['nixos-iso'][$arch]
        $oldUrl = $entry['url']
        $oldDigest = $entry['digest']

        $latestUrl = "https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-${arch}.iso"
        try {
          $request = [System.Net.WebRequest]::Create($latestUrl)
          $request.Method = 'HEAD'
          $request.AllowAutoRedirect = $true
          $response = $request.GetResponse()
          $resolvedUrl = $response.ResponseUri.AbsoluteUri
          $response.Close()
        } catch {
          Write-NucleusWarning "could not resolve ${latestUrl} for ${arch}: $($_.Exception.Message)"
          continue
        }

        $sha256Url = "${resolvedUrl}.sha256"
        try {
          $sha256Content = (Invoke-WebRequest -Uri $sha256Url -UseBasicParsing).Content
          if ($sha256Content -match '^([0-9a-f]{64})') {
            $newSha256 = $Matches[1]
          } else {
            Write-NucleusWarning "could not parse checksum from ${sha256Url}"
            continue
          }
        } catch {
          Write-NucleusWarning "could not fetch checksum for ${arch}: $($_.Exception.Message)"
          continue
        }
        $newDigest = "sha256:${newSha256}"

        if ($oldUrl -ne $resolvedUrl -or $oldDigest -ne $newDigest) {
          Write-Update -Section 'vm-setup.nixos-iso' -Key $arch -OldValue ($oldDigest -replace '^sha256:', '') -NewValue "${newSha256:0:12}..."
          $ht['vm-setup']['nixos-iso'][$arch] = @{ url = $resolvedUrl; digest = $newDigest }
        }
      }
    }
  }

  if (Test-SectionEnabled 'vm-setup.tart-images') {
    if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('tart-images') -and $ht['vm-setup']['tart-images'] -is [hashtable]) {
      foreach ($osVersion in $ht['vm-setup']['tart-images'].Keys) {
        $entry = $ht['vm-setup']['tart-images'][$osVersion]
        $oldImage = $entry['image']
        $oldDigest = $entry['digest']
        if ([string]::IsNullOrEmpty($oldImage)) { continue }

        $imageRepo = $oldImage -replace '^ghcr\.io/', ''
        if ([string]::IsNullOrEmpty($imageRepo)) {
          Write-NucleusWarning "no image repo found for ${osVersion}, skipping"
          continue
        }

        try {
          $tokenResp = Invoke-RestMethod -Uri "https://ghcr.io/token?service=ghcr.io&scope=repository:${imageRepo}:pull"
          $token = $tokenResp.token

          $headers = @{
            'Authorization' = "Bearer $token"
            'Accept' = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
          }
          $manifestResp = Invoke-WebRequest -Uri "https://ghcr.io/v2/${imageRepo}/manifests/latest" -Headers $headers -Method GET
          $newDigest = if ($manifestResp.Headers['Docker-Content-Digest']) {
            $manifestResp.Headers['Docker-Content-Digest'][0]
          } else { $null }

          if ([string]::IsNullOrEmpty($newDigest)) {
            Write-NucleusWarning "could not fetch digest for ${oldImage}, skipping"
            continue
          }

          if ($oldDigest -ne $newDigest) {
            Write-Update -Section 'vm-setup.tart-images' -Key $osVersion -OldValue "${oldDigest:0:20}..." -NewValue "${newDigest:0:20}..."
            $entry['digest'] = $newDigest
          }
        } catch {
          Write-NucleusWarning "error fetching digest for ${oldImage}: $($_.Exception.Message)"
        }
      }
    }
  }

  if ($Verify) {
    $newJson = ($ht | ConvertTo-Json -Depth 10)
    $oldJson = (Get-Content -Path $lockfileAbs -Raw -Encoding UTF8).Trim()
    if ($newJson -ne $oldJson) {
      Write-NucleusInfo 'lockfile out of date — changes would be made:'
      $oldLines = ($oldJson -split "`n")
      $newLines = ($newJson -split "`n")
      $diff = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines
      foreach ($d in $diff) {
        $marker = if ($d.SideIndicator -eq '=>') { '+' } else { '-' }
        Write-NucleusInfo "${marker} $($d.InputObject)"
      }
      exit 1
    }
    Write-NucleusInfo 'lockfile is up to date.'
    exit 0
  }

  if (-not $changed) {
    Write-NucleusInfo 'no changes — lockfile up to date'
    return
  }

  # Stamp the timestamp only when an actual change is written; a no-change run
  # must not rewrite the file (avoids timestamp churn and spurious git diffs).
  $ht['updated'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)

  # Convert hashtable back to JSON with sorted keys. Use a depth of 10 for
  # nested objects. ConvertTo-SortedJson (from JsonSort.ps1) recursively sorts
  # all object keys case-sensitively, matching the bash writer's `jq -S` behavior.
  # Append exactly one trailing newline to match `printf '%s\n'` contract.
  $outputJson = ($ht | ConvertTo-SortedJson -Depth 10) + [Environment]::NewLine

  $tmpFile = [System.IO.Path]::GetTempFileName()
  try {
    # Use UTF8 without BOM
    [System.IO.File]::WriteAllText($tmpFile, $outputJson, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmpFile -Destination $lockfileAbs -Force
    Write-NucleusInfo "wrote ${lockfileRel}"
  } catch {
    if (Test-Path -Path $tmpFile) {
      Remove-Item -Path $tmpFile -Force
    }
    throw
  }
}

# Dispatch
if ($Action -eq 'lockfile') {
  Invoke-LockfileBump -Sections $Sections -Verify:$Verify -VerifyInstalled:$VerifyInstalled -ListSections:$ListSections
} else {
  Invoke-UpdateAll -NoFlake:$NoFlake -NoSops:$NoSops
  Invoke-LockfileBump -Sections $Sections -Verify:$Verify -VerifyInstalled:$VerifyInstalled -ListSections:$ListSections
}

Write-NucleusInfo "update workflow completed"
