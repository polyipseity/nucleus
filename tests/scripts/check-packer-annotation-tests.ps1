#Requires -Version 7.4
# Tests for the packer_validate annotation check in scripts/check-packer.ps1
# (Category 1 machine-parsing invariant). Exercises the annotation check
# through the -AnnotationCheckOnly / -WindowsTemplateOverride test seams, so no
# Packer binary is required.

[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checkPacker = Join-Path $repoRoot 'scripts\check-packer.ps1'

function Assert-Pass {
    param([string]$Name)
    Write-Output "PASS $Name"
    $script:passCount++
}

function Assert-Fail {
    param([string]$Name, [string]$Reason)
    Write-Output "FAIL $Name : $Reason"
    $script:failCount++
}

$script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("check-packer-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempDir > $null

function New-Fixture {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('var-annotated', 'var-bare', 'literal-annotated', 'literal-bare', 'real-checksum')]
        [string]$Style
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Style -ne 'real-checksum') {
        $lines.Add('variable "windows_iso_checksum" {')
        $lines.Add('  type        = string')
        $lines.Add('  default     = "none"')
        $lines.Add('  description = "Windows ISO checksum."')
        $lines.Add('}')
        $lines.Add('')
    }
    switch ($Style) {
        'var-annotated' { $lines.Add('  iso_checksum = var.windows_iso_checksum # check-suppress:packer_validate: Windows ISO checksums cannot be predetermined') }
        'var-bare' { $lines.Add('  iso_checksum = var.windows_iso_checksum') }
        'literal-annotated' { $lines.Add('  iso_checksum = "none" # check-suppress:packer_validate: no stable Microsoft checksums') }
        'literal-bare' { $lines.Add('  iso_checksum = "none"') }
        'real-checksum' { $lines.Add('  iso_checksum = "abc123"') }
    }
    $path = Join-Path $script:tempDir ("fixture-" + [guid]::NewGuid().ToString('N') + '.pkr.hcl')
    Set-Content -Path $path -Value $lines -Encoding utf8
    return $path
}

function Invoke-AnnotationCheck {
    param([string]$FixturePath)
    & pwsh -NoProfile -File $script:checkPacker -AnnotationCheckOnly -WindowsTemplateOverride $FixturePath > $null 2>&1
    return $LASTEXITCODE
}

function Test-AnnotationCheck-RealChecksum {
    $fixture = New-Fixture -Style 'real-checksum'
    $exitCode = Invoke-AnnotationCheck $fixture
    if ($exitCode -eq 0) {
        Assert-Pass 'real checksum needs no annotation'
    } else {
        Assert-Fail 'real-checksum' "Expected exit 0, got $exitCode"
    }
    Remove-Item -Path $fixture -Force
}

function Test-AnnotationCheck-VarAnnotated {
    $fixture = New-Fixture -Style 'var-annotated'
    $exitCode = Invoke-AnnotationCheck $fixture
    if ($exitCode -eq 0) {
        Assert-Pass 'var "none" with annotation passes'
    } else {
        Assert-Fail 'var-annotated' "Expected exit 0, got $exitCode"
    }
    Remove-Item -Path $fixture -Force
}

function Test-AnnotationCheck-VarBare {
    $fixture = New-Fixture -Style 'var-bare'
    $exitCode = Invoke-AnnotationCheck $fixture
    if ($exitCode -ne 0) {
        Assert-Pass 'var "none" without annotation fails'
    } else {
        Assert-Fail 'var-bare' 'Expected non-zero exit for missing annotation'
    }
    Remove-Item -Path $fixture -Force
}

function Test-AnnotationCheck-LiteralAnnotated {
    $fixture = New-Fixture -Style 'literal-annotated'
    $exitCode = Invoke-AnnotationCheck $fixture
    if ($exitCode -eq 0) {
        Assert-Pass 'literal "none" with annotation passes'
    } else {
        Assert-Fail 'literal-annotated' "Expected exit 0, got $exitCode"
    }
    Remove-Item -Path $fixture -Force
}

function Test-AnnotationCheck-LiteralBare {
    $fixture = New-Fixture -Style 'literal-bare'
    $exitCode = Invoke-AnnotationCheck $fixture
    if ($exitCode -ne 0) {
        Assert-Pass 'literal "none" without annotation fails'
    } else {
        Assert-Fail 'literal-bare' 'Expected non-zero exit for missing annotation'
    }
    Remove-Item -Path $fixture -Force
}

function Test-AnnotationCheck-MissingTemplate {
    $missing = Join-Path $script:tempDir 'does-not-exist.pkr.hcl'
    $exitCode = Invoke-AnnotationCheck $missing
    if ($exitCode -eq 0) {
        Assert-Pass 'missing template is tolerated'
    } else {
        Assert-Fail 'missing-template' "Expected exit 0, got $exitCode"
    }
}

# ---- Run tests ----
Write-Output ''
Write-Output '=== packer_validate annotation check tests ==='
Write-Output ''

Test-AnnotationCheck-RealChecksum
Test-AnnotationCheck-VarAnnotated
Test-AnnotationCheck-VarBare
Test-AnnotationCheck-LiteralAnnotated
Test-AnnotationCheck-LiteralBare
Test-AnnotationCheck-MissingTemplate

Remove-Item -Path $script:tempDir -Recurse -Force

Write-Output ''
Write-Output "--- packer_validate annotation tests: $($script:passCount) passed, $($script:failCount) failed ---"
Write-Output ''

exit $script:failCount
