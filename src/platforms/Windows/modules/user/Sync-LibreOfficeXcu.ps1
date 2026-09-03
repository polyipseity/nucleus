function Sync-LibreOfficeXcu {
  <#
  .SYNOPSIS
    Applies repository-managed LibreOffice metadata-stripping entries into each managed user's registrymodifications.xcu.

  .DESCRIPTION
    Converges managed XCU entries (RemovePersonalInfoOnSave and user profile
    data fields) into each managed user's
    %APPDATA%\LibreOffice\4\user\registrymodifications.xcu without symlinks
    or hardlinks.

    LibreOffice owns registrymodifications.xcu and overwrites it on every
    close, so Method 1 (symlink) is not viable. This module uses Method 3
    (merge) to inject managed metadata-stripping entries while preserving
    any user-configured settings outside managed keys. If the XCU file does
    not exist, it is created.

    When disabled, only managed entries are removed from the XCU file;
    unmanaged content is preserved.

  .PARAMETER Enabled
    True applies managed values. False removes only managed XCU entries.

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Sync-LibreOfficeXcu -Enabled:$true -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .EXAMPLE
    Sync-LibreOfficeXcu -Enabled:$false -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [object[]]$Users,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  # OpenOffice / LibreOffice XML namespace used in XCU files.
  $OorNs = 'http://openoffice.org/2001/registry'

  # Canonical XCU header used when creating a new file.
  $XcuHeader = '<?xml version="1.0" encoding="UTF-8"?>' +
    '<!DOCTYPE oor:items PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "items.dtd">' +
    '<oor:items xmlns:oor="' + $OorNs + '"/>'

  # User profile data fields to clear. Each becomes an empty-value entry
  # under /org.openoffice.UserProfile/Data.
  $UserProfileDataFields = @(
    'c'
    'country'
    'facsimiletelephonenumber'
    'givenname'
    'homephone'
    'initials'
    'l'
    'mail'
    'o'
    'office'
    'organisational-unit'
    'postalcode'
    'position'
    'sn'
    'state'
    'street'
    'telephonenumber'
    'title'
    'url'
  )

  function Get-LibreOfficeDesiredEntries {
    <#
    .SYNOPSIS
      Reads the per-user overlay JSON and returns the managed XCU entries.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [string]$Username,

      [Parameter(Mandatory = $true)]
      [string]$RepoRoot
    )

    $settingsPath = Resolve-UserConfigFile -User $Username -ConfigName 'libreoffice' -RelativePath 'libreoffice.json' -RepoRoot $RepoRoot
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    $entries = New-Object 'System.Collections.Generic.List[pscustomobject]'

    if ($settings.removePersonalInfoOnSave -eq $true) {
      $entries.Add([pscustomobject]@{
          Path  = '/org.openoffice.Office.Common/Security/Scripting'
          Name  = 'RemovePersonalInfoOnSave'
          Value = 'true'
        })
    }

    if ($settings.clearUserProfileData -eq $true) {
      foreach ($field in $UserProfileDataFields) {
        $entries.Add([pscustomobject]@{
            Path  = '/org.openoffice.UserProfile/Data'
            Name  = $field
            Value = ''
          })
      }
    }

    if ($null -ne $settings.extraSettings) {
      foreach ($extra in $settings.extraSettings) {
        $entries.Add([pscustomobject]@{
            Path  = [string]$extra.path
            Name  = [string]$extra.name
            Value = [string]$extra.value
          })
      }
    }

    return @($entries)
  }

  function Read-XcuDocument {
    <#
    .SYNOPSIS
      Reads or creates an XCU XML document.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $xml = New-Object System.Xml.XmlDocument
      $xml.Load($Path)
      return $xml
    }

    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($XcuHeader)
    return $xml
  }

  function Write-XcuDocument {
    <#
    .SYNOPSIS
      Writes an XCU XML document to disk with UTF-8 encoding and XML declaration.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [System.Xml.XmlDocument]$Xml,

      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    $parentDir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
      New-Item -ItemType Directory -Path $parentDir -Force > $null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.Xml.XmlStreamWriter($Path, $false, $utf8NoBom)
    try {
      $writer.WriteStartDocument($true)
      $writer.WriteDocType('oor:items', $null, 'items.dtd', $null)
      $xml.DocumentElement.WriteTo($writer)
    }
    finally {
      $writer.Dispose()
    }
  }

  function Ensure-XcuItem {
    <#
    .SYNOPSIS
      Returns the <item> element matching the given oor:path, creating it if absent.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [System.Xml.XmlDocument]$Xml,

      [Parameter(Mandatory = $true)]
      [string]$ItemPath
    )

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $nsMgr.AddNamespace('oor', $OorNs)

    $items = $Xml.SelectSingleNode('/oor:items', $nsMgr)
    if ($null -eq $items) {
      $items = $Xml.CreateElement('oor', 'items', $OorNs)
      [void]$Xml.AppendChild($items)
    }

    foreach ($item in $items.ChildNodes) {
      if ($item.LocalName -eq 'item' -and $item.GetAttribute('oor:path', $OorNs) -eq $ItemPath) {
        return $item
      }
    }

    $newItem = $Xml.CreateElement('oor', 'item', $OorNs)
    $newItem.SetAttribute('oor:path', $OorNs, $ItemPath)
    [void]$items.AppendChild($newItem)
    return $newItem
  }

  function Set-XcuPropValue {
    <#
    .SYNOPSIS
      Sets or replaces the <value> inside a <prop> element.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [System.Xml.XmlDocument]$Xml,

      [Parameter(Mandatory = $true)]
      [System.Xml.XmlElement]$Prop,

      [Parameter(Mandatory = $true)]
      [string]$Value
    )

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $nsMgr.AddNamespace('oor', $OorNs)

    $valueElem = $Prop.SelectSingleNode('oor:value', $nsMgr)
    if ($null -ne $valueElem) {
      $valueElem.InnerText = $Value
    }
    else {
      $newValue = $Xml.CreateElement('oor', 'value', $OorNs)
      $newValue.InnerText = $Value
      [void]$Prop.AppendChild($newValue)
    }
  }

  function Merge-XcuEntries {
    <#
    .SYNOPSIS
      Merges managed entries into the XCU document.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [System.Xml.XmlDocument]$Xml,

      [Parameter(Mandatory = $true)]
      [pscustomobject[]]$Entries
    )

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $nsMgr.AddNamespace('oor', $OorNs)

    foreach ($entry in $Entries) {
      $item = Ensure-XcuItem -Xml $Xml -ItemPath $entry.Path

      $existingProp = $null
      foreach ($child in $item.ChildNodes) {
        if ($child.LocalName -eq 'prop' -and $child.GetAttribute('oor:name', $OorNs) -eq $entry.Name) {
          $existingProp = $child
          break
        }
      }

      if ($null -ne $existingProp) {
        Set-XcuPropValue -Xml $Xml -Prop $existingProp -Value $entry.Value
      }
      else {
        $prop = $Xml.CreateElement('oor', 'prop', $OorNs)
        $prop.SetAttribute('oor:name', $OorNs, $entry.Name)
        Set-XcuPropValue -Xml $Xml -Prop $prop -Value $entry.Value
        [void]$item.AppendChild($prop)
      }
    }
  }

  function Remove-XcuManagedEntries {
    <#
    .SYNOPSIS
      Removes managed entries from the XCU document.
    .DESCRIPTION
      For each managed entry, removes the matching <prop> from its <item>.
      If an <item> has no remaining children after cleanup, it is removed entirely.
    #>
    param(
      [Parameter(Mandatory = $true)]
      [System.Xml.XmlDocument]$Xml,

      [Parameter(Mandatory = $true)]
      [pscustomobject[]]$Entries
    )

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $nsMgr.AddNamespace('oor', $OorNs)

    foreach ($entry in $Entries) {
      $items = $Xml.SelectSingleNode('/oor:items', $nsMgr)
      if ($null -eq $items) {
        continue
      }

      foreach ($item in @($items.ChildNodes)) {
        if ($item.LocalName -ne 'item' -or $item.GetAttribute('oor:path', $OorNs) -ne $entry.Path) {
          continue
        }

        $propsToRemove = @()
        foreach ($child in $item.ChildNodes) {
          if ($child.LocalName -eq 'prop' -and $child.GetAttribute('oor:name', $OorNs) -eq $entry.Name) {
            $propsToRemove += $child
          }
        }

        foreach ($prop in $propsToRemove) {
          [void]$item.RemoveChild($prop)
        }
      }
    }

    # Remove empty items (no remaining props).
    $items = $Xml.SelectSingleNode('/oor:items', $nsMgr)
    if ($null -ne $items) {
      foreach ($item in @($items.ChildNodes)) {
        if ($item.LocalName -eq 'item' -and $item.ChildNodes.Count -eq 0) {
          [void]$items.RemoveChild($item)
        }
      }
    }
  }

  # check-suppress:config-method: method 3 (merge) -- LibreOffice owns registrymodifications.xcu and
  # overwrites it on exit. A symlink would be replaced. Merge injects managed
  # entries while preserving user-configured settings outside managed keys.
  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory
    $xcuPath = Join-Path -Path $userHome -ChildPath 'AppData\Roaming\LibreOffice\4\user\registrymodifications.xcu'
    $managedEntries = Get-LibreOfficeDesiredEntries -Username $username -RepoRoot $RepoRoot

    if ($managedEntries.Count -eq 0) {
      Write-NucleusInfo -CommandName 'Sync-LibreOfficeXcu' "No managed LibreOffice entries for $username, skipping."
      continue
    }

    if ($Enabled) {
      $xml = Read-XcuDocument -Path $xcuPath
      Merge-XcuEntries -Xml $xml -Entries $managedEntries
      Write-XcuDocument -Xml $xml -Path $xcuPath
      Write-NucleusInfo -CommandName 'Sync-LibreOfficeXcu' "LibreOffice XCU entries synced for $username."
      continue
    }

    # Cleanup: remove managed entries from the XCU file.
    if (-not (Test-Path -LiteralPath $xcuPath -PathType Leaf)) {
      Write-NucleusInfo -CommandName 'Sync-LibreOfficeXcu' "LibreOffice XCU cleanup complete for $username."
      continue
    }

    $xml = Read-XcuDocument -Path $xcuPath
    Remove-XcuManagedEntries -Xml $xml -Entries $managedEntries
    Write-XcuDocument -Xml $xml -Path $xcuPath
    Write-NucleusInfo -CommandName 'Sync-LibreOfficeXcu' "LibreOffice XCU cleanup complete for $username."
  }
}
