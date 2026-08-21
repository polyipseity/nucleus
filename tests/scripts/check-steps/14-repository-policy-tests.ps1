# Test: step 14 repository-policy PS1 must enforce dummy-key registry uniformity
# and the logging format policy

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

if ($content -match 'logging format policy') {
  Assert-Pass -Name 'step14_ps1_logging_policy_present' -Reason 'step 14 PS1 enforces the logging format policy'
} else {
  Assert-Fail -Name 'step14_ps1_logging_policy_present' -Reason 'step 14 PS1 should enforce the logging format policy'
}

if ($content -match 'raw ANSI escape literal') {
  Assert-Pass -Name 'step14_ps1_logging_ansi_pattern' -Reason 'step 14 PS1 flags raw ANSI escape literals'
} else {
  Assert-Fail -Name 'step14_ps1_logging_ansi_pattern' -Reason 'step 14 PS1 should flag raw ANSI escape literals'
}

if ($content -match 'terminal capability query') {
  Assert-Pass -Name 'step14_ps1_logging_termcap_pattern' -Reason 'step 14 PS1 flags terminal capability queries'
} else {
  Assert-Fail -Name 'step14_ps1_logging_termcap_pattern' -Reason 'step 14 PS1 should flag terminal capability queries'
}

if ($content -match 'echo dash-e flag') {
  Assert-Pass -Name 'step14_ps1_logging_echo_e_pattern' -Reason 'step 14 PS1 flags the echo dash-e flag'
} else {
  Assert-Fail -Name 'step14_ps1_logging_echo_e_pattern' -Reason 'step 14 PS1 should flag the echo dash-e flag'
}

if ($content -match 'char-27 escape literal') {
  Assert-Pass -Name 'step14_ps1_logging_char27_pattern' -Reason 'step 14 PS1 flags char-27 escape literals'
} else {
  Assert-Fail -Name 'step14_ps1_logging_char27_pattern' -Reason 'step 14 PS1 should flag char-27 escape literals'
}

if ($content -match 'backtick-e escape literal') {
  Assert-Pass -Name 'step14_ps1_logging_backtick_e_pattern' -Reason 'step 14 PS1 flags backtick-e escape literals'
} else {
  Assert-Fail -Name 'step14_ps1_logging_backtick_e_pattern' -Reason 'step 14 PS1 should flag backtick-e escape literals'
}

if ($content -match 'legacy skip marker') {
  Assert-Pass -Name 'step14_ps1_logging_skip_marker_pattern' -Reason 'step 14 PS1 flags legacy skip markers'
} else {
  Assert-Fail -Name 'step14_ps1_logging_skip_marker_pattern' -Reason 'step 14 PS1 should flag legacy skip markers'
}

if ($content -match 'Invoke-LogManagement\.ps1' -and $content -match 'log-management\.Tests\.ps1') {
  Assert-Pass -Name 'step14_ps1_logging_allowlist' -Reason 'step 14 PS1 allowlists the log sanitizer and its tests'
} else {
  Assert-Fail -Name 'step14_ps1_logging_allowlist' -Reason 'step 14 PS1 should allowlist the log sanitizer and its tests'
}

if ($content -match 'NO_COLOR') {
  Assert-Pass -Name 'step14_ps1_logging_self_check' -Reason 'step 14 PS1 self-checks NO_COLOR handling in shared helpers'
} else {
  Assert-Fail -Name 'step14_ps1_logging_self_check' -Reason 'step 14 PS1 should self-check NO_COLOR handling in shared helpers'
}

# Args mode passes positional args (which may be non-file tokens like a step id)
# straight to Select-String -Path; under Stop that throws on a missing path. The
# dummy-key scan must filter to existing files first to match the .sh twin's grep
# behavior (grep silently skips missing files).
if ($content -match 'Test-Path -LiteralPath') {
  Assert-Pass -Name 'step14_ps1_args_mode_skips_missing_paths' -Reason 'step 14 PS1 filters args-mode file lists to existing paths before Select-String'
} else {
  Assert-Fail -Name 'step14_ps1_args_mode_skips_missing_paths' -Reason 'step 14 PS1 should filter args-mode file lists to existing paths before Select-String'
}

if ($script:failed) { exit 1 } else { exit 0 }
