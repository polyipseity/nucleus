<#
.SYNOPSIS
    Guard that every literal dot-source path in the tree points at a real file.
.DESCRIPTION
    apply.ps1 dot-sources every Windows module before running any step, and a
    dot-source of a missing path is a terminating error, so a wrong relative
    path aborts an entire apply (as happened with
    '..\..\Set-ManagedSymlinkDeleteProtection.ps1' from modules/user/, which
    resolves to platforms/Windows/ instead of modules/).

    The check parses each script with the PowerShell parser, so comments and
    string literals that merely look like dot-sources are ignored, and resolves
    the two literal forms used in this repository:

        . (Join-Path -Path $PSScriptRoot -ChildPath '..\Foo.ps1')
        . "$PSScriptRoot\Foo.ps1"

    Limitation: paths built from variables (for example a temporary directory
    holding a copied module) cannot be resolved statically and are skipped.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'dot-source target integrity' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path

        $script:scanRoots = @('src', 'scripts', 'tests') | ForEach-Object { Join-Path -Path $script:repoRoot -ChildPath $_ }

        $script:scriptFiles = @(
            foreach ($root in $script:scanRoots) {
                if (Test-Path -LiteralPath $root -PathType Container) {
                    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1'
                }
            }
        )

        # Resolve the literal dot-source paths of one script.  Returns one entry
        # per literal, with the resolved target for the caller to verify.
        function Get-LiteralDotSourceTarget {
            param([System.IO.FileInfo]$File)

            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$tokens, [ref]$errors)
            if ($errors) {
                throw "Get-LiteralDotSourceTarget: $($File.FullName) does not parse: $($errors[0].Message)"
            }

            # A dot-source parses as a CommandAst whose invocation operator is
            # Dot; GetCommandName() is empty for that form.
            $commandAsts = $ast.FindAll(
                {
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
                },
                $true
            )

            foreach ($commandAst in $commandAsts) {
                if ($commandAst.CommandElements.Count -lt 1) { continue }
                # The dot is the invocation operator, so the single element is the
                # path expression itself.
                $argumentText = $commandAst.CommandElements[0].Extent.Text
                $literals = @(
                    [regex]::Matches($argumentText, "(?i)\(\s*Join-Path\s+(?:-Path\s+)?[`$]PSScriptRoot\s+(?:-ChildPath\s+)?'([^']+)'\s*\)") |
                        ForEach-Object { $_.Groups[1].Value }
                    [regex]::Matches($argumentText, '(?i)\(\s*Join-Path\s+(?:-Path\s+)?[`$]PSScriptRoot\s+(?:-ChildPath\s+)?"([^"]+)"\s*\)') |
                        ForEach-Object { $_.Groups[1].Value }
                    [regex]::Matches($argumentText, '(?i)^\s*"\$PSScriptRoot[\\/]([^"]+)"\s*$') |
                        ForEach-Object { $_.Groups[1].Value }
                    [regex]::Matches($argumentText, "(?i)^\s*'\`$PSScriptRoot[\\/]([^']+)'\s*`$") |
                        ForEach-Object { $_.Groups[1].Value }
                )
                foreach ($literal in $literals) {
                    [pscustomobject]@{
                        File    = $File.FullName
                        Literal = $literal
                        Target  = Join-Path -Path $File.DirectoryName -ChildPath ($literal -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    }
                }
            }
        }

        $script:resolved = @($script:scriptFiles | ForEach-Object { Get-LiteralDotSourceTarget -File $_ })
    }

    It 'scans the tree' {
        $script:scriptFiles.Count | Should -BeGreaterThan 100
        $script:resolved.Count | Should -BeGreaterThan 10
    }

    It 'resolves every literal dot-source path' {
        $missing = @($script:resolved | Where-Object { -not (Test-Path -LiteralPath $_.Target -PathType Leaf) })
        $report = ($missing | ForEach-Object { "$($_.File): $($_.Literal)" }) -join '; '
        $missing | Should -BeNullOrEmpty -Because "every literal dot-source must resolve: $report"
    }
}
