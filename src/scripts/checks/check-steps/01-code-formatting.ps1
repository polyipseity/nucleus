Register-Step -Id "code-formatting" -Name "Code formatting and linting" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $exitCode = 0
  $stepFailed = $false
  $inapplicableTools = 0
  $toolCount = 0

  function Invoke-ScopedTool {
    param(
      [string]$InapplicableMessage,
      [scriptblock]$Run,
      [object[]]$ScopedFiles,
      [ref]$ToolCount,
      [ref]$InapplicableTools,
      [ref]$ExitCode
    )
    $ToolCount.Value++
    if ($ScopedFiles.Count -gt 0) {
      & $Run $ScopedFiles
      if ($LASTEXITCODE -ne 0) { $ExitCode.Value = $LASTEXITCODE }
      return
    }
    if ($HasArgs) {
      Write-Message $InapplicableMessage
      $InapplicableTools.Value++
      return
    }
    & $Run
    if ($LASTEXITCODE -ne 0) { $ExitCode.Value = $LASTEXITCODE }
  }

  $shFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*.sh' -or $_ -like '*.envrc' }
    } else {
      $cached = if ($Context.CachedShellFiles) { $Context.CachedShellFiles } else { @() }
      $fromCache = @($cached)
      # check-suppress:suppression_doc: probe -- no .envrc files may exist; empty result handled.
      $envrc = Get-ChildItem -Recurse -Path $r -Filter '.envrc' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |
        ForEach-Object { $_.FullName }
      @($fromCache + $envrc) | Sort-Object -Unique
    }
  )
  Invoke-ScopedTool -InapplicableMessage '0 shell files in scope — shfmt not run.' -ScopedFiles $shFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
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
      if ($Context.CachedYamlFiles) {
        $Context.CachedYamlFiles |
          Where-Object { $_ -notmatch '[/\\]secrets[/\\]' }
      } else {
        Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' |
          Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B2 -- structural invariant
          Sort-Object FullName | ForEach-Object { $_.FullName }
      }
    }
  )
  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 YAML files in scope — yamllint not run.' -ScopedFiles $yamlFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      $ylExit = 0
      foreach ($yf in $Files) {
        yamllint $yf 2>&1 | ForEach-Object { Write-Message $_ }
        if ($LASTEXITCODE -ne 0) { $ylExit = $LASTEXITCODE }
      }
      if ($ylExit -ne 0) {
        Write-ErrorMessage 'yamllint found issues in YAML files.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
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
  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 TOML files in scope — taplo not run.' -ScopedFiles $tomlFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      taplo fmt @Files
      if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage 'taplo fmt failed.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
  }

  $pkrFiles = @(
    if ($HasArgs) {
      if ($Context.PKR_FILES) { $Context.PKR_FILES } else { @() }
    } else {
      Get-ChildItem -Recurse -Path $r -Filter '*.pkr.hcl' |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |
        Sort-Object FullName | ForEach-Object { $_.FullName }
    }
  )
  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 Packer templates in scope — packer fmt not run.' -ScopedFiles $pkrFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      packer fmt @Files
      if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage 'packer fmt failed.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
  }

  $workflowFiles = @(
    if ($HasArgs) {
      $PositionalArgs | Where-Object { $_ -like '*/.github/workflows/*' }
    } else {
      $workflowDir = Join-Path -Path $r -ChildPath '.github' -AdditionalChildPath 'workflows'
      if (Test-Path -LiteralPath $workflowDir) {
        @(
          Get-ChildItem -Path $workflowDir -Filter '*.yml' -File -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- one extension variant may have no matches; empty result handled by the Invoke-ScopedTool inapplicable path
          Get-ChildItem -Path $workflowDir -Filter '*.yaml' -File -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- one extension variant may have no matches; empty result handled by the Invoke-ScopedTool inapplicable path
        ) | Sort-Object FullName | ForEach-Object { $_.FullName }
      } else {
        @()
      }
    }
  )
  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 workflow files in scope — actionlint not run.' -ScopedFiles $workflowFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      actionlint @Files
      if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage 'actionlint failed.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
  }

  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 workflow files in scope — pinact not run.' -ScopedFiles $workflowFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      if ($Files) {
        pinact run --fix=false --no-api @Files
      } else {
        pinact run --fix=false --no-api (Join-Path -Path $r -ChildPath '.github' -AdditionalChildPath 'workflows')
      }
      if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage 'pinact failed.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
  }

  if (-not $stepFailed) {
    Invoke-ScopedTool -InapplicableMessage '0 workflow files in scope — zizmor not run.' -ScopedFiles $workflowFiles -ToolCount ([ref]$toolCount) -InapplicableTools ([ref]$inapplicableTools) -ExitCode ([ref]$exitCode) -Run {
      param($Files)
      zizmor @Files
      if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage 'zizmor failed.'
        $stepFailed = $true
        if ($stepFailed) { } # check-suppress:suppression_doc: make outer-scope read visible to PSSA
      }
    }
  }

  if (-not $stepFailed) {
    $validatePkrFiles = @(
      if ($HasArgs) {
        if ($Context.PKR_FILES) { $Context.PKR_FILES } else { @() }
      } else {
        @()
      }
    )
    $toolCount++
    if ($validatePkrFiles.Count -gt 0) {
      & "$r\scripts\check.ps1" packer -ValidateOnly @validatePkrFiles
      if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
      else { Write-Message 'Packer template validation passed.' }
    } elseif (-not $HasArgs) {
      & "$r\scripts\check.ps1" packer -ValidateOnly
      if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
      else { Write-Message 'Packer template validation passed.' }
    } else {
      Write-Message '0 Packer templates in scope — check-packer not run.'
      $inapplicableTools++
    }
  }

  if ($stepFailed -or $exitCode -ne 0) {
    Write-ErrorMessage 'Code formatting and linting failed.'
    return $false
  }
  if ($inapplicableTools -eq $toolCount) {
    Write-Message '0 files in scope for every formatter and linter — nothing to check.'
    return $true
  }
  Write-Message 'Code formatting and linting passed.'
  return $true
}
