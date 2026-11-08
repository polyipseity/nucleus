<#
.SYNOPSIS
  Pester tests for scripts/logs.ps1, the Windows half of nucleus-logs.

.DESCRIPTION
  The suite runs the real script in a child pwsh against a temporary log root, so
  the assertions cover the contract a caller sees: one canonical JSON line per
  append, a label that never rewrites existing history, concurrent appends that
  no line is lost from, copy-truncate rotation with a gzip archive, and expiry of
  archives past the retention window.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/scripts/logs.Tests.ps1"
#>

BeforeAll {
  # check-suppress:suppression_doc: deterministic color state -- color init runs
  # at import, so NO_COLOR pins plain output for the whole suite.
  $env:NO_COLOR = '1'

  $script:PwshExe = (Get-Command pwsh).Source
  # WHY forward slashes: the suite also runs on POSIX, where a backslash is a
  # literal filename character rather than a separator.
  $script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../../../..')).Path
  $script:LogsPs1 = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/logs.ps1'
  $script:Work = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-logs-" + [guid]::NewGuid().ToString())
  $null = New-Item -ItemType Directory -Path $script:Work -Force

  $env:NUCLEUS_REPO_ROOT = $script:RepoRoot
  $env:NUCLEUS_LOG_DIR = $script:Work

  function Invoke-Logs {
    param(
      [Parameter(Mandatory)][string[]]$Arguments,
      [string]$InputLine
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:PwshExe
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    foreach ($argument in @('-NoProfile', '-NoLogo', '-File', $script:LogsPs1) + $Arguments) {
      $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # WHY: both streams are read asynchronously; draining one to the end while the
    # child fills the other stream's buffer can deadlock.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputLine) { $process.StandardInput.WriteLine($InputLine) }
    $process.StandardInput.Close()
    $process.WaitForExit()
    return [pscustomobject]@{
      Stdout   = $stdout.Result
      Stderr   = $stderr.Result
      ExitCode = $process.ExitCode
    }
  }

  function Get-LogLine {
    param([Parameter(Mandatory)][string]$LogName)
    $path = Join-Path -Path $script:Work -ChildPath "$LogName.log"
    return @(Get-Content -LiteralPath $path)
  }
}

AfterAll {
  if (Test-Path -LiteralPath $script:Work) {
    Remove-Item -LiteralPath $script:Work -Recurse -Force
  }
}

Describe 'nucleus-logs append' {
  It 'writes one line carrying every canonical key' {
    $result = Invoke-Logs -Arguments @('append', '-Log', 'decisions') -InputLine '{"id":"one","kind":"decision"}'
    $result.ExitCode | Should -Be 0

    $lines = @(Get-LogLine -LogName "decisions")
    $lines.Count | Should -Be 1

    $event = $lines[0] | ConvertFrom-Json
    foreach ($key in @('ts', 'id', 'kind', 'harness', 'decision', 'source', 'filter', 'rule', 'latency_ms', 'summary', 'digest')) {
      $event.PSObject.Properties.Name | Should -Contain $key
    }
    $event.id | Should -Be 'one'
  }

  It 'refuses an event over the 4096-byte limit' {
    $big = 'x' * 5000
    $result = Invoke-Logs -Arguments @('append', '-Log', 'decisions') -InputLine ('{"id":"big","summary":"' + $big + '"}')
    $result.ExitCode | Should -Not -Be 0
    ($result.Stderr -join '') | Should -BeLike '*4096*'
  }
}

Describe 'nucleus-logs label' {
  It 'appends a kind=label event and leaves earlier lines untouched' {
    $before = @(Get-LogLine -LogName 'decisions')

    $result = Invoke-Logs -Arguments @('label', '-Id', 'one', '-Verdict', 'deny', '-Note', 'reviewed by hand')
    $result.ExitCode | Should -Be 0

    $after = @(Get-LogLine -LogName "decisions")
    $after.Count | Should -Be ($before.Count + 1)
    for ($index = 0; $index -lt $before.Count; $index++) {
      $after[$index] | Should -Be $before[$index]
    }

    $label = $after[-1] | ConvertFrom-Json
    $label.kind | Should -Be 'label'
    $label.id | Should -Be 'one'
    $label.decision | Should -Be 'deny'
    $label.summary | Should -Be 'reviewed by hand'
  }
}

Describe 'nucleus-logs concurrency' {
  It 'keeps every line of 12 concurrent appends parseable' {
    $processes = @()
    for ($i = 1; $i -le 12; $i++) {
      $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
      $startInfo.FileName = $script:PwshExe
      $startInfo.UseShellExecute = $false
      $startInfo.RedirectStandardOutput = $true
      $startInfo.RedirectStandardError = $true
      $startInfo.RedirectStandardInput = $true
      foreach ($argument in @('-NoProfile', '-NoLogo', '-File', $script:LogsPs1, 'append', '-Log', 'concurrent')) {
        $startInfo.ArgumentList.Add($argument)
      }
      $process = [System.Diagnostics.Process]::Start($startInfo)
      $null = $process.StandardOutput.ReadToEndAsync()
      $null = $process.StandardError.ReadToEndAsync()
      $process.StandardInput.WriteLine(('{{"id":"c{0:d2}","kind":"concurrent"}}' -f $i))
      $process.StandardInput.Close()
      $processes += $process
    }
    foreach ($process in $processes) {
      $process.WaitForExit()
      $process.ExitCode | Should -Be 0
    }

    $lines = @(Get-LogLine -LogName "concurrent")
    $lines.Count | Should -Be 12
    $ids = @()
    foreach ($line in $lines) {
      $event = $line | ConvertFrom-Json
      $event.kind | Should -Be 'concurrent'
      $ids += $event.id
    }
    ($ids | Sort-Object -Unique).Count | Should -Be 12
  }
}

Describe 'nucleus-logs rotate and expire' {
  It 'archives an oversized log and truncates it in place' {
    $path = Join-Path -Path $script:Work -ChildPath 'rotate-me.log'
    $payload = '{"id":"rot","summary":"' + ('y' * 3000) + '"}'
    Set-Content -LiteralPath $path -Value $payload -NoNewline
    $null = Add-Content -LiteralPath $path -Value ([Environment]::NewLine)

    $result = Invoke-Logs -Arguments @('rotate', '-MaxSize', '1024', '-MaxFiles', '4', '-Compress', 'true')
    $result.ExitCode | Should -Be 0

    # WHY the .1.log naming: Invoke-LogRotation, the shared Windows rotation, names
    # archives <base>.<N>.log.gz, unlike the POSIX <log>.log.<N>.gz form.
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'rotate-me.1.log.gz')) | Should -BeTrue
    (Get-Item -LiteralPath $path).Length | Should -Be 0

    $inputStream = [System.IO.File]::OpenRead((Join-Path -Path $script:Work -ChildPath 'rotate-me.1.log.gz'))
    try {
      $gzip = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
      try {
        $reader = [System.IO.StreamReader]::new($gzip)
        try {
          ($reader.ReadToEnd() | ConvertFrom-Json).id | Should -Be 'rot'
        } finally { $reader.Dispose() }
      } finally { $gzip.Dispose() }
    } finally { $inputStream.Dispose() }
  }

  It 'removes an archive older than the expiry and keeps a fresh one' {
    $old = Join-Path -Path $script:Work -ChildPath 'expire-me.log.1.gz'
    $fresh = Join-Path -Path $script:Work -ChildPath 'expire-me.log.2.gz'
    foreach ($target in @($old, $fresh)) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"id":"x"}')
      $fileStream = [System.IO.File]::Create($target)
      try {
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Compress)
        try { $gzipStream.Write($bytes, 0, $bytes.Length) } finally { $gzipStream.Dispose() }
      } finally { $fileStream.Dispose() }
    }
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)

    $result = Invoke-Logs -Arguments @('expire', '-Expiry', '7d')
    $result.ExitCode | Should -Be 0

    (Test-Path -LiteralPath $old) | Should -BeFalse
    (Test-Path -LiteralPath $fresh) | Should -BeTrue
  }
}

Describe 'nucleus-logs help' {
  It 'prints help and exits 0' {
    $result = Invoke-Logs -Arguments @('-Help')
    $result.ExitCode | Should -Be 0
    ($result.Stdout -join '') | Should -BeLike '*nucleus-logs*'
  }
}
