Register-Step -Id "windows-pester" -Number 6 -Name "Windows Pester tests" -Action {
  param($RepoRoot)

  # Provisioning: materialize env-parity manifest from the Nix catalog before
  # EnvVarParity.Tests.ps1 runs. Preflight only reads the generated JSON file.
  $manifestDir = Join-Path $RepoRoot 'result'
  $manifestFile = Join-Path $manifestDir 'env-parity-manifest.json'
  if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
  }

  if (-not (Get-Command -Name nix -ErrorAction SilentlyContinue)) {
    throw 'nix is required to materialize result/env-parity-manifest.json for Windows Pester tests'
  }

  $nixTestFile = Join-Path $RepoRoot 'tests\integration\env-parity-tests.nix'
  $json = & nix eval --impure --file $nixTestFile manifest --json
  if ($LASTEXITCODE -ne 0) {
    throw "nix eval failed for env-parity manifest (exit $LASTEXITCODE)"
  }
  [System.IO.File]::WriteAllText($manifestFile, $json)

  $windowsTestRoots = @(
    (Join-Path $RepoRoot 'tests\platforms\Windows')
    (Join-Path $RepoRoot 'tests\hosts\Windows')
  )
  $testFiles = @(
    foreach ($root in $windowsTestRoots) {
      if (Test-Path $root) {
        Get-ChildItem -Path $root -Recurse -File |
          Where-Object { $_.Name -like '*.Tests.ps1' -or $_.Name -like '*.tests.ps1' } |
          ForEach-Object { $_.FullName }
      }
    }
  )

  if ($testFiles.Count -eq 0) {
    Write-Message 'no Pester test files found; skipping.'
    return 2
  }

  $result = Invoke-Pester -Path $testFiles -PassThru
  return ($result.FailedCount -eq 0)
}
