# Test: step 14 repository-policy PS1 must enforce dummy-key registry uniformity

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'

$repoRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/checks/check-steps/14-repository-policy.ps1'
$registryFile = Join-Path -Path $repoRoot -ChildPath 'src/modules/dummy-keys.json'
$script:failed = $false

function Assert-Pass {
  param($Name, $Reason)
  Write-Output "PASS $Name : $Reason"
}

function Assert-Fail {
  param($Name, $Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failed = $true
}

$content = Get-Content -Path $testFile -Raw
$registryContent = Get-Content -Path $registryFile -Raw

if ($content -match 'dummy-keys\.json') {
  Assert-Pass -Name 'step14_ps1_dummy_key_registry_read' -Reason 'step 14 PS1 reads the dummy-key registry from dummy-keys.json'
} else {
  Assert-Fail -Name 'step14_ps1_dummy_key_registry_read' -Reason 'step 14 PS1 should read the dummy-key registry from dummy-keys.json'
}

if ($content -match 'sk-\[A-Za-z0-9\]\{4,\}') {
  Assert-Pass -Name 'step14_ps1_dummy_key_literal_pattern' -Reason 'step 14 PS1 targets sk-[A-Za-z0-9]{4,} API key literals'
} else {
  Assert-Fail -Name 'step14_ps1_dummy_key_literal_pattern' -Reason 'step 14 PS1 should target sk-[A-Za-z0-9]{4,} API key literals'
}

if ($content -match 'unregistered dummy API key literal') {
  Assert-Pass -Name 'step14_ps1_dummy_key_error_path' -Reason 'step 14 PS1 errors on unregistered dummy API key literals'
} else {
  Assert-Fail -Name 'step14_ps1_dummy_key_error_path' -Reason 'step 14 PS1 should error on unregistered dummy API key literals'
}

if ($registryContent -match 'sk-nucleus-dummy-litellm') {
  Assert-Pass -Name 'step14_ps1_dummy_key_registered_value' -Reason 'dummy-key registry registers the sk-nucleus-dummy-litellm value'
} else {
  Assert-Fail -Name 'step14_ps1_dummy_key_registered_value' -Reason 'dummy-key registry should register the sk-nucleus-dummy-litellm value'
}

if ($content -match 'activation naming policy') {
  Assert-Pass -Name 'step14_ps1_naming_policy_present' -Reason 'step 14 PS1 enforces the activation naming policy'
} else {
  Assert-Fail -Name 'step14_ps1_naming_policy_present' -Reason 'step 14 PS1 should enforce the activation naming policy'
}

if ($content -match '\^\[a-z\]\[a-z0-9\]\*\(-\[a-z0-9\]\+\)\*\$') {
  Assert-Pass -Name 'step14_ps1_naming_kebab_regex' -Reason 'step 14 PS1 validates activation names against the kebab-case regex'
} else {
  Assert-Fail -Name 'step14_ps1_naming_kebab_regex' -Reason 'step 14 PS1 should validate activation names against the kebab-case regex'
}

if ($content -match 'linkGeneration|writeBoundary|checkLinkTargets|setupLaunchAgents|installPackages|preActivation|extraActivation|postActivation') {
  Assert-Pass -Name 'step14_ps1_naming_exemption_names' -Reason 'step 14 PS1 exempts Home Manager built-in and nix-darwin hardcoded activation names'
} else {
  Assert-Fail -Name 'step14_ps1_naming_exemption_names' -Reason 'step 14 PS1 should exempt Home Manager built-in and nix-darwin hardcoded activation names'
}

if ($content -match 'unprotectSymlink|protectSymlink|mergeConfig') {
  Assert-Pass -Name 'step14_ps1_naming_generated_exemption' -Reason 'step 14 PS1 exempts config-utils.nix generated activation names'
} else {
  Assert-Fail -Name 'step14_ps1_naming_generated_exemption' -Reason 'step 14 PS1 should exempt config-utils.nix generated activation names'
}

if ($content -match 'lacks the macos- prefix') {
  Assert-Pass -Name 'step14_ps1_naming_macos_prefix_error' -Reason 'step 14 PS1 requires the macos- prefix on macOS-only activation names'
} else {
  Assert-Fail -Name 'step14_ps1_naming_macos_prefix_error' -Reason 'step 14 PS1 should require the macos- prefix on macOS-only activation names'
}

if ($content -match 'cnotmatch') {
  Assert-Pass -Name 'step14_ps1_naming_case_sensitive' -Reason 'step 14 PS1 keeps the kebab regex case-sensitive (-cnotmatch)'
} else {
  Assert-Fail -Name 'step14_ps1_naming_case_sensitive' -Reason 'step 14 PS1 should keep the kebab regex case-sensitive (-cnotmatch)'
}

if ($script:failed) { exit 1 } else { exit 0 }
