#Requires -Version 5.1
<#
.SYNOPSIS
  Deploys safe-delete PATH shims for Windows (rip.exe copies for all aliases).

.DESCRIPTION
  Copies rip.exe to <USER root>\bin with names rm.exe, del.exe, rd.exe, rmdir.exe, erase.exe, ri.exe.
  These are also copied to %USERPROFILE%\.local\bin for PATH coverage. Follows HarnessBridge pattern.

.PARAMETER Enabled
  Mandatory. Deploy or remove.

.PARAMETER RepoRoot
  Absolute path to live repository root.

.PARAMETER UserRoot
  Absolute path to nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

.PARAMETER UserProfile
  Absolute path to user profile (%USERPROFILE%).

.EXAMPLE
  Sync-SafeDelete -Enabled:$true -RepoRoot $repoRoot -UserRoot (Get-NucleusUserRoot) -UserProfile $HOME
#>
function Sync-SafeDelete {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)] [bool]$Enabled,
    [Parameter(Mandatory = $true)] [string]$RepoRoot,
    [Parameter(Mandatory = $true)] [string]$UserRoot,
    [Parameter(Mandatory = $true)] [string]$UserProfile
  )

  $binDir = Join-Path -Path $UserRoot -ChildPath 'bin'
  $shimDir = Join-Path -Path $UserProfile -ChildPath '.local\bin'
  $names = @('rm.exe', 'del.exe', 'rd.exe', 'rmdir.exe', 'erase.exe', 'ri.exe')

  if (-not $Enabled) {
    foreach ($n in $names) {
      Remove-Item -LiteralPath (Join-Path $binDir $n) -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $shimDir $n) -Force -ErrorAction SilentlyContinue
    }
    return
  }

  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

  # Find rip.exe from scoop or system
  $rip = $null
  $candidates = @(
    (Join-Path $UserProfile 'scoop\apps\rip\current\rip.exe'),
    (Join-Path $UserProfile 'scoop\shims\rip.exe'),
    (Get-Command rip.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $rip = $c; break }
  }

  if (-not $rip) {
    Write-NucleusWarning -CommandName 'Sync-SafeDelete' 'rip.exe not found; PATH shims not deployed (ensure rip2/scoop installed)'
    return
  }

  foreach ($n in $names) {
    try {
      Copy-Item -LiteralPath $rip -Destination (Join-Path $binDir $n) -Force
    } catch {
      Write-NucleusWarning -CommandName 'Sync-SafeDelete' "failed to deploy $n to bin: $_"
    }
    try {
      Copy-Item -LiteralPath $rip -Destination (Join-Path $shimDir $n) -Force
    } catch {
      Write-NucleusWarning -CommandName 'Sync-SafeDelete' "failed to deploy $n to .local\bin: $_"
    }
  }

  # Clink Lua filter
  $clinkDir = Join-Path $env:LOCALAPPDATA 'clink'
  New-Item -ItemType Directory -Force -Path $clinkDir | Out-Null
  $lua = @'
-- SafeDelete: intercept rm/del/rd/rmdir/erase and route to rip
local function is_interactive() return true end
clink.onfilterinput(function(text)
    local cmd, rest = text:match("^%s*(%a+)%s*(.*)")
    if cmd then
        local lcmd = cmd:lower()
        if lcmd == "del" or lcmd == "erase" or lcmd == "rd" or lcmd == "rmdir" or lcmd == "rm" then
            if is_interactive() then
                io.write("[SafeDelete Notice] Redirecting to rip.\n")
            end
            local clean_args = rest:gsub("/[fFsSqQpP]", "")
            return "rip.exe " .. clean_args
        end
    end
    return text
end)
'@
  $luaPath = Join-Path $clinkDir 'safedel.lua'
  Set-Content -LiteralPath $luaPath -Value $lua -Encoding UTF8
}
