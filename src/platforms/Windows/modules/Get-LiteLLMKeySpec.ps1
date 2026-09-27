<#
.SYNOPSIS
  Selects the LiteLLM key specs from the env-secrets catalog.

.DESCRIPTION
  The LiteLLM gateway needs one environment variable per AI provider key. On
  POSIX those come from envLib.mkSecretArgsForConsumer in
  src/modules/lib/env-secrets.nix, which filters secrets.secrets by consumer
  name and returns KEYFILE:ENVVAR pairs for src/scripts/services/litellm-daemon.sh
  to export. The filter therefore has exactly one meaning: "this secret is
  consumed by litellm".

  This function is the Windows half of that same filter, reading the same
  catalog file (src/modules/env/env-secrets.json) that the Nix side derives
  from. Both hosts select the identical set because both read the identical
  data and apply the identical predicate.

.NOTES
  Requirements: none.
  Environment variables: none.
#>

function Get-LiteLLMKeySpec {
    <#
    .SYNOPSIS
      Returns the catalog entries whose consumers include litellm.

    .DESCRIPTION
      Missing or unreadable input is a terminating error rather than a warning
      and an empty result. A silently empty key set is indistinguishable from a
      healthy gateway with no credentials: litellm starts, answers /health, and
      fails only at request time with an empty key. The neighbouring checks in
      Sync-LiteLLMService.ps1 already treat a missing litellm config source and a
      missing custom handler as throws, and this is the same class of required
      repository input.

    .PARAMETER CatalogPath
      Full path to env-secrets.json.

    .OUTPUTS
      System.Management.Automation.PSCustomObject[]
      One object per litellm secret, carrying the catalog's own name and envVar
      fields. The file field is not produced here: the key file location is the
      wrapper's to resolve.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "env-secrets catalog not found: $CatalogPath"
    }

    # ConvertFrom-Json raises a terminating error on malformed input, so an
    # unparseable catalog stops the apply rather than yielding an empty set.
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json

    if ($null -eq $catalog.secrets) {
        throw "env-secrets catalog has no 'secrets' array: $CatalogPath"
    }

    # -contains on the wrapped array is the predicate mkSecretArgsForConsumer
    # applies with builtins.elem. Wrapping guards a scalar consumers value, which
    # -contains on a bare string would reject for being the wrong type.
    foreach ($entry in @($catalog.secrets)) {
        if (@($entry.consumers) -contains 'litellm') {
            [PSCustomObject]@{
                name   = $entry.name
                envVar = $entry.envVar
            }
        }
    }
}
