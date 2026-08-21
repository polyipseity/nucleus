# JsonSort.ps1 — deterministic JSON serialization helpers for Windows tooling.
#
# Generated JSON artifacts committed to the repo (e.g. winget-packages.json,
# lockfile.json) must be byte-stable across runs so diffs show only real
# changes. ConvertTo-Json does NOT sort object keys (it preserves insertion
# order) and Set-Content -NoNewline strips the trailing newline, so callers
# that write committed artifacts must sort keys/arrays and append a newline.
#
# These helpers produce multi-line, 2-space-indented JSON with sorted keys and
# sorted arrays and a single trailing newline, matching the Nix `toSortedJSON`
# helper in src/modules/lib/json.nix.

using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Text

# Recursively sort object keys case-sensitively and array elements (when all
# elements are strings) so the serialized output is deterministic.
function Sort-JsonObject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [AllowNull()]
    $InputObject
  )

  process {
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [Hashtable] -or $InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
      $sorted = [Ordered]@{}
      $keys = @($InputObject.Keys) | Sort-Object -CaseSensitive
      foreach ($key in $keys) {
        $sorted[$key] = Sort-JsonObject -InputObject $InputObject[$key]
      }
      return $sorted
    }

    if ($InputObject -is [IList]) {
      $list = @($InputObject)
      if ($list.Count -gt 0 -and ($list | Where-Object { $_ -isnot [string] }).Count -eq 0) {
        $list = $list | Sort-Object -CaseSensitive
      }
      $result = [List[object]]::new()
      foreach ($item in $list) { $result.Add((Sort-JsonObject -InputObject $item)) }
      return $result
    }

    return $InputObject
  }
}

# Serialize a value to a deterministic JSON string: multi-line, 2-space
# indented, sorted keys, sorted string arrays, and exactly one trailing newline.
function ConvertTo-SortedJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [AllowNull()]
    $InputObject,

    [int]$Depth = 10
  )

  process {
    $sorted = Sort-JsonObject -InputObject $InputObject
    # ConvertTo-Json without -Compress emits 2-space-indented multi-line JSON
    # and a single trailing newline, matching the Nix toSortedJSON helper.
    return ConvertTo-Json -InputObject $sorted -Depth $Depth
  }
}
