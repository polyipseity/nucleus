# tests/integration/svc-tests.nix — Schema and invariant tests for service management.
#
# Validates that the service registry (services.json), backends (svc.sh,
# svc.ps1), and wiring (flake.nix, shell.nix, check scripts) contain the
# required structural elements.
#
# Run with: nix-instantiate --eval tests/integration/svc-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  svcShText = builtins.readFile ../../scripts/svc.sh;
  svcPs1Text = builtins.readFile ../../scripts/svc.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
  windowsShellProfileText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

  # Parsed services.json for structural assertions
  parsedServices = builtins.fromJSON servicesJsonText;
  serviceNames = builtins.filter (n: n != "\$schema" && n != "\$defaults") (
    builtins.attrNames parsedServices
  );

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
assert containsRegex ''"service-watchdog"'' servicesJsonText;
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
assert containsRegex "do_logs" svcShText;
assert containsRegex "do_log_paths" svcShText;
assert containsRegex "do_log_config" svcShText;
assert containsRegex "get_platform_services" svcShText;
assert containsRegex "get_capture" svcShText;
assert containsRegex "get_unit" svcShText;
assert containsRegex "service_log_files" svcShText;
assert containsRegex "service_has_logs" svcShText;
assert containsRegex "show_file_logs" svcShText;
assert containsRegex "show_journald_logs" svcShText;
assert containsRegex ''services\.json'' svcShText;
assert containsRegex "launchctl" svcShText;
assert containsRegex "systemctl" svcShText;

# --- svc.ps1 structural assertions ---
assert containsRegex "Resolve-ServiceName" svcPs1Text;
assert containsRegex "Get-ServiceStatus" svcPs1Text;
assert containsRegex "Invoke-ServiceAction" svcPs1Text;
assert containsRegex "Format-StatusTable" svcPs1Text;
assert containsRegex "Get-CaptureMode" svcPs1Text;
assert containsRegex "Get-ServiceLogFile" svcPs1Text;
assert containsRegex "Test-ServiceHasLog" svcPs1Text;
assert containsRegex "Show-ServiceLog" svcPs1Text;
assert containsRegex "Show-ServiceList" svcPs1Text;
assert containsRegex "Show-LogConfig" svcPs1Text;
assert containsRegex ''services\.json'' svcPs1Text;
assert containsRegex "Get-Service" svcPs1Text;
assert containsRegex "ScheduledTask" svcPs1Text;

# --- svc.sh column format assertions ---
assert containsRegex "ID" svcShText;
assert containsRegex "%-20s" svcShText;
assert containsRegex "%-24s" svcShText;

# --- svc.ps1 column format assertions ---
assert containsRegex "ID" svcPs1Text;
assert containsRegex "[{]0,-20}" svcPs1Text;
assert containsRegex "[{]1,-24}" svcPs1Text;

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

# --- flake.nix nucleusApps wiring assertions ---
assert containsRegex "nucleus-svc" flakeText;
assert containsRegex ''name = "svc"'' flakeText;

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
# All 11 subcommands present in both backends
assert builtins.all (x: containsRegex x svcShText) [
  "endpoint"
  "logs"
  "log-paths"
  "log-config"
  "list"
  "status"
  "start"
  "stop"
  "restart"
  "enable"
  "disable"
];
assert builtins.all (x: containsRegex ("'" + x + "'") svcPs1Text) [
  "endpoint"
  "logs"
  "log-paths"
  "log-config"
  "list"
  "status"
  "start"
  "stop"
  "restart"
  "enable"
  "disable"
];
# Both backends have consistent error message prefix
# svc.sh: prefix auto-derived via shared error/warn helpers from lib.sh
assert containsRegex "error \"" svcShText;
assert containsRegex "svc:" svcPs1Text;

# --- Dispatch wiring (explicit function mapping) ---
# svc.sh action dispatch: special-case actions use explicit function names
# (catches regression where "do_$action" produced invalid function names)
assert containsRegex "log-paths[)] do_log_paths" svcShText;
assert containsRegex "log-config[)] do_log_config" svcShText;
assert containsRegex "endpoint[)] do_endpoint" svcShText;
assert containsRegex "list[|]status[|]logs[)] \"do_\\$action\"" svcShText;
assert containsRegex "start[|]stop[|]restart[|]enable[|]disable[)] do_action" svcShText;
# do_log_config parses --json via global json_output (not a local variable)
assert containsRegex "--json[)] json_output=true" svcShText;
true
