Register-Step -Id "schema-validation" -Name "Schema validation (JSON/YAML)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  # Single source of truth for A8 exception list: files that don't need $schema.
  # Policy: nucleus-owned data requires $schema (we write our own schemas).
  # External formats: use published $schema when available; never roll our own.
  # ref: allow-and-deny-lists.instructions.md#A8
  function Skip-SchemaFile([string]$FilePath) {
    $f = $FilePath
    return (
      # Schema definitions / meta
      $f -like '*.schema.json' -or
      # External formats (no published schema available)
      $f -like '*users\*\cursor\*.json' -or $f -like '*users/*/cursor/*.json' -or
      $f -like '*users\*\iterm2\DynamicProfiles\*.json' -or $f -like '*users/*/iterm2/DynamicProfiles/*.json' -or
      $f -like '*users\*\obsidian\*.json' -or $f -like '*users/*/obsidian/*.json' -or
      $f -like '*users\*\qtpass\*.json' -or $f -like '*users/*/qtpass/*.json' -or
      $f -like '*users\*\rimsort\*.json' -or $f -like '*users/*/rimsort/*.json' -or
      $f -like '*configs\camilladsp\*' -or $f -like '*configs/camilladsp/*' -or
      $f -like '*configs\camillagui-backend\*' -or $f -like '*configs/camillagui-backend/*' -or
      $f -like '*users\*\discord-music-rpc\*' -or $f -like '*users/*/discord-music-rpc/*' -or
      $f -like '*users\*\agents\hooks\*.json' -or $f -like '*users/*/agents/hooks/*.json' -or
      $f -like '*users\*\agents\skills\*\_meta.json' -or $f -like '*users/*/agents/skills/*/_meta.json' -or
      $f -like '*configs\litellm\*' -or $f -like '*configs/litellm/*' -or
      $f -like '*users\*\hermes\plugins\*\plugin.yaml' -or $f -like '*users/*/hermes/plugins/*/plugin.yaml' -or
      $f -like '*users\*\vscode\mcp.json' -or $f -like '*users/*/vscode/mcp.json' -or
      $f -like '*users\*\vscode\chatLanguageModels*.json' -or $f -like '*users/*/vscode/chatLanguageModels*.json' -or
      $f -like '*\.sops.yaml' -or $f -like '*/.sops.yaml' -or
      $f -like '*.yamllint.yml' -or
      # Infrastructure
      $f -like '*\vendor\*' -or $f -like '*/vendor/*' -or
      $f -like '*\secrets\*' -or $f -like '*/secrets/*' -or
      $f -like '*.github\*' -or $f -like '*.github/*'
    )
  }

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs
  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # Build manifest of file->schema pairs.
  $manifest = [System.Collections.Generic.List[hashtable]]::new()

  if ($HasArgs) {
    foreach ($sf in $PositionalArgs) {
      # Normalize relative paths to absolute so exception patterns match consistently.
      $absSf = if ([System.IO.Path]::IsPathRooted($sf)) { $sf } else { [System.IO.Path]::GetFullPath((Join-Path $r $sf)) }
      if (Skip-SchemaFile $absSf) { continue }
      if ($absSf -like '*.json') {
        $schema = try { (Get-Content $absSf -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
        # Skip external schema URLs (HTTP/HTTPS) — not local schema files; check-jsonschema would try to download them.
        if ($schema -and $schema -notmatch '^https?://') {
          $schemafile = if ($schema -match '^\.') { [System.IO.Path]::GetFullPath((Join-Path (Split-Path $absSf -Parent) $schema)) } else { $schema }
          $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $absSf })
        }
      } elseif ($absSf -like '*.yml' -or $absSf -like '*.yaml') {
        $schema = try { (ConvertFrom-Yaml -Yaml (Get-Content $absSf -Raw))['$schema'] } catch { $null }
        # Skip external schema URLs (HTTP/HTTPS) — not local schema files; check-jsonschema would try to download them.
        if ($schema -and $schema -notmatch '^https?://') {
          $schemafile = if ($schema -match '^\.') { [System.IO.Path]::GetFullPath((Join-Path (Split-Path $absSf -Parent) $schema)) } else { $schema }
          $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $absSf })
        }
      }
    }
  } else {
    # JSON files
    Get-ChildItem -Recurse -Path "$r/src" -Filter '*.json' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json'  # ref: allow-and-deny-lists.instructions.md#B3,#A7 -- structural invariants; schema files are meta
    } | ForEach-Object {
      $schema = try { (Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable)['$schema'] } catch { $null }
      # Skip external schema URLs (HTTP/HTTPS) — not local schema files; check-jsonschema would try to download them.
      if ($schema -and $schema -notmatch '^https?://') {
        if ($schema -match '^\.') {
          $schemafile = [System.IO.Path]::GetFullPath((Join-Path $_.DirectoryName $schema))
        } else {
          $schemafile = $schema
        }
        $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $_.FullName })
      }
    }
    # YAML files
    Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]'  # ref: allow-and-deny-lists.instructions.md#B3 -- structural invariant; gitignore filter applied on top
    } | ForEach-Object { $_.FullName } | Select-GitIgnored | ForEach-Object {
      $schema = try { (ConvertFrom-Yaml -Yaml (Get-Content $_ -Raw))['$schema'] } catch { $null }
      # Skip external schema URLs (HTTP/HTTPS) — not local schema files; check-jsonschema would try to download them.
      if ($schema -and $schema -notmatch '^https?://') {
        if ($schema -match '^\.') {
          $schemafile = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_ -Parent) $schema))
        } else {
          $schemafile = $schema
        }
        $manifest.Add(@{SchemaFile = $schemafile; InstanceFile = $_ })
      }
    }
  }

  $jsonschemaErrors = 0

  # $schema presence and format check (Spec G)


  # Collect all files in scope for $schema presence check
  $allFiles = [System.Collections.Generic.List[string]]::new()
  if ($HasArgs) {
    foreach ($sf in $PositionalArgs) {
      # Normalize relative paths to absolute so exception patterns match consistently.
      $absSf = if ([System.IO.Path]::IsPathRooted($sf)) { $sf } else { [System.IO.Path]::GetFullPath((Join-Path $r $sf)) }
      if ($absSf -like '*.json' -or $absSf -like '*.yml' -or $absSf -like '*.yaml') {
        $allFiles.Add($absSf)
      }
    }
  } else {
    Get-ChildItem -Recurse -Path "$r/src" -Filter '*.json' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.Name -notlike '*.schema.json'  # ref: allow-and-deny-lists.instructions.md#B3,#A7 -- structural invariants; schema files are meta
    } | ForEach-Object { $allFiles.Add($_.FullName) }
    Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' | Where-Object {
      $_.FullName -notmatch '[/\\]vendor[/\\]'  # ref: allow-and-deny-lists.instructions.md#B3 -- structural invariant; gitignore filter applied on top
    } | ForEach-Object { $_.FullName } | Select-GitIgnored | ForEach-Object { $allFiles.Add($_) }
  }

  foreach ($f in $allFiles) {
    if (Skip-SchemaFile $f) { continue }

    if ($f -like '*.json') {
      # Skip non-object JSON (arrays, primitives) — they cannot have root-level $schema.
      $content = try { Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
      if ($null -eq $content -or $content -isnot [System.Collections.Hashtable]) {
        continue
      }
      $hasSchema = $content.ContainsKey('$schema')
      if ($hasSchema) {
        $schemaVal = $content['$schema']
        if ([string]::IsNullOrEmpty($schemaVal)) {
          Write-ErrorMessage "Invalid `$schema in ${f}: must be a non-empty string"
          $jsonschemaErrors++
        }
      } else {
        Write-ErrorMessage "Missing `$schema in $f"
        $jsonschemaErrors++
      }
    } elseif ($f -like '*.yml' -or $f -like '*.yaml') {
      $content = try { Get-Content $f -Raw | ConvertFrom-Yaml } catch { $null }
      $hasSchema = $content -and $content.ContainsKey('$schema')
      if ($hasSchema) {
        $schemaVal = $content['$schema']
        if ([string]::IsNullOrEmpty($schemaVal)) {
          Write-ErrorMessage "Invalid `$schema in ${f}: must be a non-empty string"
          $jsonschemaErrors++
        }
      } else {
        Write-ErrorMessage "Missing `$schema in $f"
        $jsonschemaErrors++
      }
    }
  }

  if ($manifest.Count -gt 0) {
    # Group by schemafile and validate sequentially.
    $groups = $manifest | Group-Object SchemaFile
    foreach ($group in $groups) {
      $schemaFile = $group.Name
      $instanceFiles = @($group.Group.InstanceFile)
      $output = check-jsonschema --schemafile $schemaFile $instanceFiles 2>&1
      if ($LASTEXITCODE -ne 0) {
        $jsonschemaErrors++
        Write-ErrorMessage "$output"
      }
    }
  }

  # GitHub schema validation -- always-run
  $ghWorkflowDir = Join-Path -Path $r -ChildPath '.github' -AdditionalChildPath 'workflows'
  $ghWorkflows = @(Get-ChildItem -Path $ghWorkflowDir -Filter '*.yml' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })  # check-suppress:suppression_doc: probe -- .github/workflows may be absent; empty result is handled by the .Count -gt 0 guard below
  if ($ghWorkflows.Count -gt 0) {
    check-jsonschema --builtin-schema vendor.github-workflows $ghWorkflows
    if ($LASTEXITCODE -ne 0) { $jsonschemaErrors++ }
  }

  $dependabot = Join-Path $r '.github\dependabot.yml'
  if (Test-Path $dependabot) {
    check-jsonschema --builtin-schema vendor.dependabot $dependabot
    if ($LASTEXITCODE -ne 0) { $jsonschemaErrors++ }
  }

  if ($jsonschemaErrors -gt 0) {
    Write-ErrorMessage "schema validation failed with $jsonschemaErrors error(s)"
    return $false
  }
  Write-Message "schema validation passed."
  return $true
}
