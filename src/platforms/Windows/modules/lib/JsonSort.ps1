# JsonSort.ps1 - deterministic JSON serialization for Windows tooling.
#
# Committed JSON artifacts must be byte-stable so diffs show only real changes.
# ConvertTo-Json keeps insertion order and Set-Content -NoNewline drops the
# trailing newline, so callers sort first and this module appends one newline.
# Output matches the Nix toSortedJSON helper in src/modules/lib/json.nix.

using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Text

# Sorts object keys case-sensitively and string-only array elements.
function ConvertTo-SortedJsonObject {
  [CmdletBinding()]
  # WHY: the input can also be a raw scalar or $null, so the declared types are
  # the container shapes only.
  [OutputType([System.Collections.Specialized.OrderedDictionary], [System.Collections.Generic.List[object]])]
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
        $sorted[$key] = ConvertTo-SortedJsonObject -InputObject $InputObject[$key]
      }
      return $sorted
    }

    if ($InputObject -is [IList]) {
      $list = @($InputObject)
      if ($list.Count -gt 0 -and ($list | Where-Object { $_ -isnot [string] }).Count -eq 0) {
        $list = $list | Sort-Object -CaseSensitive
      }
      $result = [List[object]]::new()
      foreach ($item in $list) { $result.Add((ConvertTo-SortedJsonObject -InputObject $item)) }
      return $result
    }

    return $InputObject
  }
}

function ConvertTo-SortedJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [AllowNull()]
    $InputObject,

    [int]$Depth = 10
  )

  process {
    $sorted = ConvertTo-SortedJsonObject -InputObject $InputObject
    # Without -Compress, ConvertTo-Json emits 2-space-indented multi-line JSON
    # and a single trailing newline.
    return ConvertTo-Json -InputObject $sorted -Depth $Depth
  }
}
