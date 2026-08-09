Register-Step -Id "code-formatting" -Number 1 -Name "Code formatting and linting" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $exitCode = 0
  $skippedTools = 0
  $toolCount = 0

  function Invoke-ScopedTool {
    param(
      [string]$SkipMessage,
      [scriptblock]$Run,
      [object[]]$ScopedFiles
    )
    $script:toolCount++
    if ($ScopedFiles.Count -gt 0) {
      & $Run $ScopedFiles
      if ($LASTEXITCODE -ne 0) { $script:exitCode = $LASTEXITCODE }
      return
    }
    if ($HasArgs) {
      Write-Message $SkipMessage
      $script:skippedTools++
      return
    }
    & $Run
    if ($LASTEXITCODE -ne 0) { $script:exitCode = $LASTEXITCODE }
  }

  $shFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*.sh' -or $_ -like '*.envrc' }
    } else {
      $cached = if ($script:CachedShFiles) { $script:CachedShFiles } else { @() }
      $fromCache = @($cached | ForEach-Object { $_.FullName })
      $envrc = Get-ChildItem -Recurse -Path $r -Filter '.envrc' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |
        ForEach-Object { $_.FullName }
      @($fromCache + $envrc) | Sort-Object -Unique
    }
  )
  Invoke-ScopedTool -SkipMessage 'skipping shfmt (no shell files to check).' -ScopedFiles $shFiles -Run {
    param($Files)
    if ($Files) {
      shfmt -w @Files
    } else {
      Get-ChildItem -Recurse -Path $r -Include '*.sh', '.envrc' -Force |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B2 -- structural invariant
        ForEach-Object { $_.FullName } |
        ForEach-Object { shfmt -w $_ }
    }
    if ($LASTEXITCODE -eq 0) { Write-Message 'shfmt passed.' }
  }

  $yamlFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
    } else {
      if ($script:CachedYamlFiles) {
        $script:CachedYamlFiles |
          Where-Object { $_.FullName -notmatch '[/\\]secrets[/\\]' } |
          ForEach-Object { $_.FullName }
      } else {
        Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' |
          Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B2 -- structural invariant
          Sort-Object FullName | ForEach-Object { $_.FullName }
      }
    }
  )
  Invoke-ScopedTool -SkipMessage 'skipping yamllint (no YAML files to check).' -ScopedFiles $yamlFiles -Run {
    param($Files)
    $ylExit = 0
    foreach ($yf in $Files) {
      yamllint $yf 2>&1 | ForEach-Object { Write-Output "check: $_" }
      if ($LASTEXITCODE -ne 0) { $ylExit = $LASTEXITCODE }
    }
    if ($ylExit -ne 0) { throw 'yamllint found issues in YAML files.' }
    Write-Message 'yamllint passed.'
  }

  $tomlFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*.toml' }
    } else {
      Get-ChildItem -Recurse -Path $r -Filter '*.toml' |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B2 -- structural invariant
        Sort-Object FullName | ForEach-Object { $_.FullName }
    }
  )
  Invoke-ScopedTool -SkipMessage 'skipping taplo (no TOML files to check).' -ScopedFiles $tomlFiles -Run {
    param($Files)
    taplo fmt @Files
    if ($LASTEXITCODE -ne 0) { throw 'taplo fmt failed.' }
    Write-Message 'taplo passed.'
  }

  $pkrFiles = @(
    if ($HasArgs) {
      if ($script:PKR_FILES) { $script:PKR_FILES } else { @() }
    } else {
      Get-ChildItem -Recurse -Path $r -Filter '*.pkr.hcl' |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |
        Sort-Object FullName | ForEach-Object { $_.FullName }
    }
  )
  Invoke-ScopedTool -SkipMessage 'skipping packer fmt (no Packer templates to check).' -ScopedFiles $pkrFiles -Run {
    param($Files)
    packer fmt @Files
    if ($LASTEXITCODE -ne 0) { throw 'packer fmt failed.' }
    Write-Message 'packer fmt passed.'
  }

  $workflowFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*/.github/workflows/*' }
    } else {
      $workflowDir = Join-Path $r '.github\workflows'
      if (Test-Path -LiteralPath $workflowDir) {
        Get-ChildItem -Path $workflowDir -Include '*.yml', '*.yaml' -Recurse |
          Sort-Object FullName | ForEach-Object { $_.FullName }
      } else {
        @()
      }
    }
  )
  Invoke-ScopedTool -SkipMessage 'skipping actionlint (no workflow files to check).' -ScopedFiles $workflowFiles -Run {
    param($Files)
    actionlint @Files
    if ($LASTEXITCODE -ne 0) { throw 'actionlint failed.' }
    Write-Message 'actionlint passed.'
  }

  Invoke-ScopedTool -SkipMessage 'skipping pinact (no workflow files to check).' -ScopedFiles $workflowFiles -Run {
    param($Files)
    if ($Files) {
      pinact run --fix=false --no-api @Files
    } else {
      pinact run --fix=false --no-api (Join-Path $r '.github\workflows')
    }
    if ($LASTEXITCODE -ne 0) { throw 'pinact failed.' }
    Write-Message 'pinact passed.'
  }

  Invoke-ScopedTool -SkipMessage 'skipping zizmor (no workflow files to check).' -ScopedFiles $workflowFiles -Run {
    param($Files)
    zizmor @Files
    if ($LASTEXITCODE -ne 0) { throw 'zizmor failed.' }
    Write-Message 'zizmor passed.'
  }

  $validatePkrFiles = @(
    if ($HasArgs) {
      if ($script:PKR_FILES) { $script:PKR_FILES } else { @() }
    } else {
      @()
    }
  )
  $toolCount++
  if ($validatePkrFiles.Count -gt 0) {
    & "$r\scripts\check-packer.ps1" -ValidateOnly @validatePkrFiles
    if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
    else { Write-Message 'Packer template validation passed.' }
  } elseif (-not $HasArgs) {
    & "$r\scripts\check-packer.ps1" -ValidateOnly
    if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
    else { Write-Message 'Packer template validation passed.' }
  } else {
    Write-Message 'skipping check-packer (no Packer templates to check).'
    $skippedTools++
  }

  if ($exitCode -ne 0) {
    Write-ErrorMessage 'Code formatting and linting failed.'
    return $false
  }
  if ($skippedTools -eq $toolCount) {
    return 2
  }
  Write-Message 'Code formatting and linting passed.'
  return $true
}
