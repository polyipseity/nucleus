<#
.SYNOPSIS
    Shared output formatting for nucleus-* PowerShell scripts.
.DESCRIPTION
    Provides Write-NucleusInfo, Write-NucleusError, Write-NucleusWarning,
    Write-NucleusDryRun, Write-NucleusDone, and Write-NucleusNotice functions
    that format output consistently across all nucleus-* commands.

    These functions auto-derive the command name from the script path, so
    callers don't need to pass a prefix; pass -CommandName to override the
    label (F1 grammar). Info/DryRun/Done/Notice are colored with $PSStyle when
    the console supports it; Error/Warning are left to host rendering.
    Semantic inline coloring (URLs -> underline cyan, single-quoted spans ->
    blue) is applied to message text only when color is on; output is
    byte-identical to plain text otherwise.

    Usage:
        Import-Module Format-NucleusOutput
        Write-NucleusInfo "processing 3 files"
        Write-NucleusInfo "syncing" -CommandName replica-sync
        Write-NucleusError "file not found"
        Write-NucleusWarning "deprecated flag"
        Write-NucleusDryRun "would delete $path"
        Write-NucleusNotice "reboot pending"
        Write-NucleusDone
#>

# One-time color detection at import (console-only invariant, F spec).
# NO_COLOR wins; FORCE_COLOR (not "0") / CLICOLOR_FORCE force on; otherwise
# virtual-terminal support AND output not redirected. $PSStyle.OutputRendering
# is NOT touched — the engine owns NO_COLOR/TERM handling.
$script:NucleusColorOn = $false
if ($env:NO_COLOR) {
    $script:NucleusColorOn = $false
} elseif (($env:FORCE_COLOR -and $env:FORCE_COLOR -ne '0') -or $env:CLICOLOR_FORCE) {
    $script:NucleusColorOn = $true
} elseif ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) {
    $script:NucleusColorOn = $true
}

# Semantic inline tokenizer (F spec, "more console colors"): single-quoted
# spans -> blue, URLs -> underline cyan, only when color is on; byte-identical
# passthrough otherwise. Quote pass runs first so URLs inside quotes still read
# as URLs. Mirrors _nuc_semantic_color in src/scripts/lib/lib.sh.
function ConvertTo-NucleusSemanticColor {
    param(
        [string]$Text
    )
    if (-not $script:NucleusColorOn -or -not $Text) { return $Text }
    $blue = $PSStyle.Foreground.Blue
    $underlineCyan = "$($PSStyle.Underline)$($PSStyle.Foreground.Cyan)"
    $reset = $PSStyle.Reset
    $result = [regex]::Replace($Text, "'[^']*'", { param($m) "${blue}$($m.Value)${reset}" })
    $result = [regex]::Replace($result, 'https?://[^\s''"]*', { param($m) "${underlineCyan}$($m.Value)${reset}" })
    return $result
}

# Internal F1 formatter for the stdout helpers (Info/DryRun/Done/Notice).
# Embeds color around the label and level word only when $script:NucleusColorOn
# is set; plain-string variant otherwise. No timestamp support yet (F1 allows
# optional [<ts> ]); both POSIX and PS1 sides currently omit it.
function Format-NucleusMessage {
    param(
        [string]$CommandName,
        [string]$Level = '',
        [string]$Message = ''
    )
    if (-not $script:NucleusColorOn) {
        switch ($Level) {
            'dry-run' { return "$CommandName`: [dry-run] $Message" }
            'done' { return "$CommandName`: done" }
            'notice' { return "$CommandName`: [notice] $Message" }
            default { return "$CommandName`: $Message" }
        }
    }
    $label = "$($PSStyle.Bold)$CommandName$($PSStyle.Reset)"
    $message = ConvertTo-NucleusSemanticColor -Text $Message
    switch ($Level) {
        'dry-run' {
            $token = "$($PSStyle.Bold)$($PSStyle.Foreground.Magenta)[dry-run]$($PSStyle.Reset)"
            return "$label`: $token $message"
        }
        'done' {
            $token = "$($PSStyle.Bold)$($PSStyle.Foreground.Green)done$($PSStyle.Reset)"
            return "$label`: $token"
        }
        'notice' {
            $token = "$($PSStyle.Bold)$($PSStyle.Foreground.Blue)[notice]$($PSStyle.Reset)"
            return "$label`: $token $message"
        }
        default {
            return "$label`: $message"
        }
    }
}

# Auto-derive the short command name from the script path.
# e.g., "scripts/gc.ps1" → "gc", "nucleus-gc" → "gc"
function Get-NucleusCommandName {
    <#
    .SYNOPSIS
        Derive the short command name for the F1 output prefix.
    .PARAMETER Path
        Script path to derive from (defaults to the current command's file).
    #>
    param(
        [string]$Path = $PSCommandPath
    )
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -like 'nucleus-*') {
        $name = $name.Substring(8) # strip 'nucleus-'
    }
    return $name
}

function Write-NucleusInfo {
    <#
    .SYNOPSIS
        Print an info message to stdout.
    .PARAMETER Message
        The message text (without prefix).
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    #>
    param(
        [string]$Message,
        [string]$CommandName = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    Write-Output (Format-NucleusMessage -CommandName $CommandName -Message $Message)
}

function Write-NucleusError {
    <#
    .SYNOPSIS
        Print an error message to stderr.
    .PARAMETER Message
        The message text (without prefix).
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    .PARAMETER ErrorAction
        Optional -ErrorAction passthrough for Write-Error (e.g. 'Continue' to
        keep the error non-terminating under $ErrorActionPreference='Stop').
        Defaults to '' (flagless; ambient caller preference applies).
    #>
    param(
        [string]$Message,
        [string]$CommandName = '',
        [string]$ErrorAction = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    if ($script:NucleusColorOn) { $Message = ConvertTo-NucleusSemanticColor -Text $Message }
    if ($ErrorAction) {
        Write-Error "$CommandName`: error: $Message" -ErrorAction $ErrorAction
    }
    else {
        Write-Error "$CommandName`: error: $Message"
    }
}

function Write-NucleusWarning {
    <#
    .SYNOPSIS
        Print a warning message to stderr.
    .PARAMETER Message
        The message text (without prefix).
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    #>
    param(
        [string]$Message,
        [string]$CommandName = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    if ($script:NucleusColorOn) { $Message = ConvertTo-NucleusSemanticColor -Text $Message }
    Write-Warning "$CommandName`: warning: $Message"
}

function Write-NucleusDryRun {
    <#
    .SYNOPSIS
        Print a dry-run message to stdout.
    .PARAMETER Message
        The action description (without prefix).
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    #>
    param(
        [string]$Message,
        [string]$CommandName = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    Write-Output (Format-NucleusMessage -CommandName $CommandName -Level 'dry-run' -Message $Message)
}

function Write-NucleusDone {
    <#
    .SYNOPSIS
        Print a completion message to stdout.
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    #>
    param(
        [string]$CommandName = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    Write-Output (Format-NucleusMessage -CommandName $CommandName -Level 'done')
}

function Write-NucleusNotice {
    <#
    .SYNOPSIS
        Print a notice message to stdout.
    .PARAMETER Message
        The message text (without prefix).
    .PARAMETER CommandName
        Optional label override (defaults to the derived command name).
    #>
    param(
        [string]$Message,
        [string]$CommandName = ''
    )
    if (-not $CommandName) { $CommandName = Get-NucleusCommandName }
    Write-Output (Format-NucleusMessage -CommandName $CommandName -Level 'notice' -Message $Message)
}

Export-ModuleMember -Function Get-NucleusCommandName, Write-NucleusInfo, Write-NucleusError, Write-NucleusWarning, Write-NucleusDryRun, Write-NucleusDone, Write-NucleusNotice
