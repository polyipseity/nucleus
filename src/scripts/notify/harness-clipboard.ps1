#!/usr/bin/env pwsh
<#
.SYNOPSIS
Copies stdin to the system clipboard through one shared command.

.DESCRIPTION
Reads the text on stdin and copies it. Exits 0 on success, non-zero with a named
reason when no backend exists. Backend order: Set-Clipboard on Windows, then
pbcopy, clip.exe, wl-copy, and `xclip -selection clipboard`. The environment
variable NUCLEUS_CLIPBOARD_BACKEND overrides the selection for tests and callers
that know the backend name.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Read stdin once so every backend receives the same text verbatim.
$content = [Console]::In.ReadToEnd()

function Invoke-ClipboardBackend {
  param(
    [Parameter(Mandatory)]
    [string] $Backend,
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string] $Text
  )

  switch ($Backend) {
    'Set-Clipboard' {
      Set-Clipboard -Value $Text
      return
    }
    'pbcopy' {
      $cmd = Get-Command pbcopy -ErrorAction SilentlyContinue # check-suppress:suppression_doc: backend absence is expected during probe
      if (-not $cmd) { throw "clipboard backend unavailable: pbcopy" }
      $Text | & $cmd.Source
      return
    }
    'clip.exe' {
      $cmd = Get-Command clip.exe -ErrorAction SilentlyContinue # check-suppress:suppression_doc: backend absence is expected during probe
      if (-not $cmd) { throw "clipboard backend unavailable: clip.exe" }
      $Text | & $cmd.Source
      return
    }
    'wl-copy' {
      $cmd = Get-Command wl-copy -ErrorAction SilentlyContinue # check-suppress:suppression_doc: backend absence is expected during probe
      if (-not $cmd) { throw "clipboard backend unavailable: wl-copy" }
      $Text | & $cmd.Source
      return
    }
    'xclip -selection clipboard' {
      $cmd = Get-Command xclip -ErrorAction SilentlyContinue # check-suppress:suppression_doc: backend absence is expected during probe
      if (-not $cmd) { throw "clipboard backend unavailable: xclip" }
      $Text | & $cmd.Source -selection clipboard
      return
    }
    default {
      throw "clipboard backend unavailable: $Backend"
    }
  }
}

$backend = $env:NUCLEUS_CLIPBOARD_BACKEND
if ([string]::IsNullOrEmpty($backend)) {
  $isWin = ($IsWindows -or ($env:OS -eq 'Windows_NT'))
  if ($isWin -and (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) { # check-suppress:suppression_doc: backend absence is expected during probe
    $backend = 'Set-Clipboard'
  }
  elseif (Get-Command pbcopy -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: backend absence is expected during probe
    $backend = 'pbcopy'
  }
  elseif (Get-Command clip.exe -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: backend absence is expected during probe
    $backend = 'clip.exe'
  }
  elseif (Get-Command wl-copy -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: backend absence is expected during probe
    $backend = 'wl-copy'
  }
  elseif (Get-Command xclip -ErrorAction SilentlyContinue) { # check-suppress:suppression_doc: backend absence is expected during probe
    $backend = 'xclip -selection clipboard'
  }
  else {
    [Console]::Error.WriteLine('no clipboard backend available (tried Set-Clipboard, pbcopy, clip.exe, wl-copy, xclip)')
    exit 1
  }
}

try {
  Invoke-ClipboardBackend -Backend $backend -Text $content
  exit 0
}
catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
