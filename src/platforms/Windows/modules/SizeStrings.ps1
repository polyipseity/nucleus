# SizeStrings.ps1 — suffixed size string parsing shared by VM provisioning.
# Implements the IDENTICAL grammar as src/modules/lib/size.nix and
# src/scripts/lib/size.sh; keep all three in sync.

function ConvertFrom-SizeString {
    <#
    .SYNOPSIS
        Parses a suffixed size string (^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$)
        into an exact byte count.

    .DESCRIPTION
        Decimal prefixes (kB/MB/GB/TB) multiply by powers of 10; binary
        prefixes (kiB/MiB/GiB/TiB) by powers of 2.  A single optional space
        between the number and the prefix is allowed.  The grammar is
        case-sensitive (KB/KiB are invalid); invalid strings throw a
        terminating error.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string]$SizeString
    )

    if ($SizeString -cmatch '^([0-9]+) ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$') {
        $number = [long]$Matches[1]
        $suffix = $Matches[2]
        $factor = switch ($suffix) {
            'kB' { 1000 }
            'MB' { 1000000 }
            'GB' { 1000000000 }
            'TB' { 1000000000000 }
            'kiB' { 1024 }
            'MiB' { 1048576 }
            'GiB' { 1073741824 }
            'TiB' { 1099511627776 }
        }
        return $number * $factor
    }
    throw "invalid size string '$SizeString' (expected ^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$)"
}
