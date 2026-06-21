# tests/src/svc-tests.nix — Schema and invariant tests for service management.
#
# Validates that the service registry (services.json), backends (svc.sh,
# svc.ps1), and wiring (flake.nix, shell.nix, check scripts) contain the
# required structural elements.
#
# Run with: nix-instantiate --eval tests/src/svc-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  svcShText = builtins.readFile ../../scripts/svc.sh;
  svcPs1Text = builtins.readFile ../../scripts/svc.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  shellNixText = builtins.readFile ../../src/modules/shell.nix;
  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

  # Parsed services.json for structural assertions
  parsedServices = builtins.fromJSON servicesJsonText;
  serviceNames = builtins.filter (n: n != "\$schema") (builtins.attrNames parsedServices);

  # Tail-recursive list helpers
  all =
    pred: list:
    if list == [ ] then
      true
    else if pred (builtins.head list) then
      all pred (builtins.tail list)
    else
      false;
  any =
    pred: list:
    if list == [ ] then
      false
    else if pred (builtins.head list) then
      true
    else
      any pred (builtins.tail list);
in

# --- services.json structural assertions ---
assert containsRegex ''\$schema.*services\.schema\.json'' servicesJsonText;
assert containsRegex ''"ollama"'' servicesJsonText;
assert containsRegex ''"litellm"'' servicesJsonText;
assert containsRegex ''"jellyfin"'' servicesJsonText;
assert containsRegex ''"discord-music-rpc"'' servicesJsonText;
assert containsRegex ''"sshd"'' servicesJsonText;
assert containsRegex ''"ssh-agent"'' servicesJsonText;
assert containsRegex ''"cloud-drive"'' servicesJsonText;
assert containsRegex ''"rdp"'' servicesJsonText;
assert containsRegex ''"linux-builder"'' servicesJsonText;
assert containsRegex ''"displayName"'' servicesJsonText;
assert containsRegex "prefixMatch" servicesJsonText;

# --- svc.sh structural assertions ---
assert containsRegex "read_registry" svcShText;
assert containsRegex "resolve_service_names" svcShText;
assert containsRegex "svc_status" svcShText;
assert containsRegex "svc_action" svcShText;
assert containsRegex "do_list" svcShText;
assert containsRegex "do_status" svcShText;
assert containsRegex "do_action" svcShText;
assert containsRegex ''services\.json'' svcShText;
assert containsRegex "launchctl" svcShText;
assert containsRegex "systemctl" svcShText;

# --- svc.ps1 structural assertions ---
assert containsRegex "Resolve-ServiceName" svcPs1Text;
assert containsRegex "Get-ServiceStatus" svcPs1Text;
assert containsRegex "Invoke-ServiceAction" svcPs1Text;
assert containsRegex "Format-StatusTable" svcPs1Text;
assert containsRegex ''services\.json'' svcPs1Text;
assert containsRegex "Get-Service" svcPs1Text;
assert containsRegex "ScheduledTask" svcPs1Text;

# --- svc.sh bug-fix assertions ---
assert containsRegex ''type == "object"'' svcShText;
assert containsRegex "value: .displayName" svcShText;
assert containsRegex "awk -v label=" svcShText;
assert containsRegex "jq -c '.platform'" svcShText;
assert containsRegex "filtered_service_names" svcShText;

# --- svc.ps1 bug-fix assertions ---
assert containsRegex "entry -is " svcPs1Text;

# --- flake.nix wiring assertions ---
assert containsRegex "mkSvcApp" flakeText;
assert containsRegex "svc = mkSvcApp pkgsMac" flakeText;
assert containsRegex "svc = mkSvcApp pkgsLinux" flakeText;
assert containsRegex "runtimeInputs.*jq" flakeText;

# --- shell.nix wiring assertions ---
assert containsRegex "nucleus-svc" shellNixText;
assert containsRegex ''mkNucleusCommand "nucleus-svc" "svc"'' shellNixText;

# --- services.json scope assertions ---
# ollama and litellm are system-wide on macOS.
assert containsRegex ''"ollama".*"macos".*"system"'' servicesJsonText;
assert containsRegex ''"litellm".*"macos".*"system"'' servicesJsonText;

# User-scoped entries must have justification.
assert containsRegex ''"discord-music-rpc".*justification'' servicesJsonText;
assert containsRegex ''"ssh-agent".*justification'' servicesJsonText;
assert containsRegex ''"cloud-drive".*justification'' servicesJsonText;

# --- check.sh service registry validation assertions ---
assert containsRegex "Service registry validation" checkShText;
assert containsRegex ''services\.json'' checkShText;
assert containsRegex "justification" checkShText;
assert containsRegex "users.json" checkShText;

# --- check.ps1 service registry validation assertions ---
assert containsRegex "Service registry validation" checkPs1Text;
assert containsRegex ''services\.json'' checkPs1Text;
assert containsRegex "justification" checkPs1Text;
assert containsRegex "users.json" checkPs1Text;

# --- Windows profile wiring assertions ---
assert containsRegex "nucleus-svc" windowsShellProfileText;
assert containsRegex "scripts\\\\svc\\.ps1" windowsShellProfileText;

# --- endpoint subcommand presence in both backends ---
assert containsRegex "do_endpoint" svcShText;
assert containsRegex "'endpoint'" svcPs1Text;
assert containsRegex "endpoint_name" svcShText;

# --- --json flag handling in both backends ---
assert containsRegex "json_output" svcShText;
assert containsRegex ''\$Json'' svcPs1Text;

# --- Structural: each service has at least one non-omitted platform ---
assert all (
  name:
  let
    entry = parsedServices.${name};
    platforms = builtins.attrNames entry.platforms;
  in
  any (p: entry.platforms.${p}.type != "omitted") platforms
) serviceNames;

# --- Structural: all host platform keys are valid (macos, nixos, windows) ---
assert all (
  name:
  let
    entry = parsedServices.${name};
    knownPlatforms = [
      "macos"
      "nixos"
      "windows"
    ];
  in
  all (p: any (kp: kp == p) knownPlatforms) (builtins.attrNames entry.platforms)
) serviceNames;

# --- Schema reference integrity ---
assert containsRegex ''services\.schema\.json'' servicesJsonText;

# --- Phase C: Structural/parse assertions ---
# read_registry jq filter syntax
assert containsRegex "to_entries.*map" svcShText;
assert containsRegex "select.*type == .object." svcShText;
# --json handled before action (the filtered_service_names loop)
assert containsRegex "filtered_service_names" svcShText;
assert containsRegex "json_output=true" svcShText;
# $Json switch parameter in svc.ps1 param block
assert containsRegex "switch.*\\\$Json" svcPs1Text;
# Error: service not found in both backends
assert containsRegex "service not found" svcShText;
assert containsRegex "service not found in registry" svcPs1Text;
# Error: unsupported host in svc.sh
assert containsRegex "unsupported host" svcShText;
# Unknown action error in both backends
assert containsRegex "unsupported argument" svcShText;
assert containsRegex "missing action" svcShText;
assert containsRegex "missing action" svcPs1Text;

# --- Phase E: Cross-host parity assertions ---
# All 8 subcommands handled in svc.sh case statement
assert
  containsRegex "list" svcShText
  && containsRegex "status" svcShText
  && containsRegex "start" svcShText
  && containsRegex "stop" svcShText;
assert
  containsRegex "restart" svcShText
  && containsRegex "enable" svcShText
  && containsRegex "disable" svcShText
  && containsRegex "endpoint" svcShText;
# All 8 subcommands handled in svc.ps1 switch statement
assert containsRegex "'list'" svcPs1Text && containsRegex "'status'" svcPs1Text;
assert
  containsRegex "'start'" svcPs1Text
  && containsRegex "'stop'" svcPs1Text
  && containsRegex "'restart'" svcPs1Text;
assert
  containsRegex "'enable'" svcPs1Text
  && containsRegex "'disable'" svcPs1Text
  && containsRegex "'endpoint'" svcPs1Text;
# Both backends have consistent error message prefix
assert containsRegex "svc:" svcShText;
assert containsRegex "svc:" svcPs1Text;
true
