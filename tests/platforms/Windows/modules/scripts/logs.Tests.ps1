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
  It 'appends a kind=label event to the harness log and leaves earlier lines untouched' {
    $null = Invoke-Logs -Arguments @('label', '-Id', 'seed', '-Verdict', 'correct', '-Note', 'seed event')
    $before = @(Get-LogLine -LogName 'harness')
    $before.Count | Should -Be 1

    $result = Invoke-Logs -Arguments @('label', '-Id', 'one', '-Verdict', 'false-deny', '-Note', 'reviewed by hand')
    $result.ExitCode | Should -Be 0

    $after = @(Get-LogLine -LogName 'harness')
    $after.Count | Should -Be ($before.Count + 1)
    for ($index = 0; $index -lt $before.Count; $index++) {
      $after[$index] | Should -Be $before[$index]
    }

    $label = $after[-1] | ConvertFrom-Json
    $label.kind | Should -Be 'label'
    $label.id | Should -Be 'one'
    $label.verdict | Should -Be 'false-deny'
    $label.note | Should -Be 'reviewed by hand'
    $label.source | Should -Be 'none'
  }
}

Describe 'nucleus-logs name validation' {
  It 'rejects an empty log name without creating a lock in the current directory' {
    Push-Location -Path $script:RepoRoot
    try {
      $command = ". '$($script:LogsPs1)'; Add-NucleusLogEvent -LogName '' -Event @{ id = 'x' }"
      & $script:PwshExe -NoProfile -NonInteractive -Command $command > $null 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      (Test-Path -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.lock')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.log')) | Should -BeFalse
    } finally {
      Pop-Location
    }
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

Describe 'nucleus-logs tolerates a native writer' {
  It 'appends while another handle holds the log open for writing' {
    $path = Join-Path $script:Work 'native.log'
    # WHY this holder: a service redirecting stdout into the log holds the file
    # open for writing. The append must wait on the lock sidecar, never on the
    # log itself, or every event would time out behind the native writer.
    $holder = [System.IO.FileStream]::new(
      $path,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite)
    try {
      $nativeBytes = [System.Text.Encoding]::UTF8.GetBytes("native line`n")
      $holder.Write($nativeBytes, 0, $nativeBytes.Length)
      $holder.Flush()

      $result = Invoke-Logs -Arguments @('append', '-Log', 'native') -InputLine '{"id":"n1","kind":"decision"}'
      $result.ExitCode | Should -Be 0
      (Get-Content -LiteralPath $path).Count | Should -Be 2
    } finally {
      $holder.Dispose()
    }
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

  It 'shows events from an uncompressed archive' {
    # WHY: with compression off, rotation leaves <base>.1.log as plain text, and a
    # reader that always inflates would fail on every show.
    $path = Join-Path -Path $script:Work -ChildPath 'plain.log'
    Set-Content -LiteralPath $path -Value ('{"id":"rot","summary":"' + ('y' * 3000) + '"}')

    $result = Invoke-Logs -Arguments @('rotate', '-MaxSize', '1024', '-Compress', 'false')
    $result.ExitCode | Should -Be 0
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'plain.1.log')) | Should -BeTrue

    $show = Invoke-Logs -Arguments @('show', '-Log', 'plain', '-Json')
    $show.ExitCode | Should -Be 0
    $ids = @(($show.Stdout -join "`n") | ConvertFrom-Json).id
    $ids | Should -Contain 'rot'
  }

  It 'does not list an uncompressed archive as its own log' {
    $stats = Invoke-Logs -Arguments @('stats', '-Json')
    $stats.ExitCode | Should -Be 0
    $names = @(($stats.Stdout -join "`n") | ConvertFrom-Json).log
    $names | Should -Not -Contain 'plain.1'
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
