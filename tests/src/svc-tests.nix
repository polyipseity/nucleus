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
in

# --- services.json structural assertions ---
assert containsRegex ''\$schema.*services\.schema\.json'' servicesJsonText;
assert containsRegex ''"ollama"'' servicesJsonText;
assert containsRegex ''"litellm"'' servicesJsonText;
assert containsRegex ''"jellyfin"'' servicesJsonText;
assert containsRegex ''"jellyfin-https"'' servicesJsonText;
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
assert containsRegex "servy-cli" svcPs1Text;
assert containsRegex "ScheduledTask" svcPs1Text;

# --- flake.nix wiring assertions ---
assert containsRegex "mkSvcApp" flakeText;
assert containsRegex "svc = mkSvcApp pkgsMac" flakeText;
assert containsRegex "svc = mkSvcApp pkgsLinux" flakeText;
assert containsRegex "runtimeInputs.*jq" flakeText;

# --- shell.nix wiring assertions ---
assert containsRegex "nucleus-svc" shellNixText;
assert containsRegex ''mkNucleusCommand "nucleus-svc" "svc"'' shellNixText;

# --- check.sh service registry validation assertions ---
assert containsRegex "Service registry validation" checkShText;
assert containsRegex ''services\.json'' checkShText;

# --- check.ps1 service registry validation assertions ---
assert containsRegex "Service registry validation" checkPs1Text;
assert containsRegex ''services\.json'' checkPs1Text;
true
