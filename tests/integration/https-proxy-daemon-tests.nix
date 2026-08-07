# tests/integration/https-proxy-daemon-tests.nix — httpsProxy daemon env and state path.

let
  inherit (import ../lib.nix) containsRegex;

  macbookHttpsProxyText = builtins.readFile ../../src/hosts/MacBook/https-proxy.nix;
  httpsProxyDaemonShText = builtins.readFile ../../src/scripts/services/https-proxy-daemon.sh;
in

assert containsRegex "NUCLEUS_REPO_ROOT = resolveValue \"NUCLEUS_REPO_ROOT\"" macbookHttpsProxyText;
assert containsRegex "NUCLEUS_SYSTEM_LOG_DIR = systemLogDir" macbookHttpsProxyText;
assert containsRegex "nucleus_caddy_state_dir" httpsProxyDaemonShText;
assert !(containsRegex "/Users/Shared/https-proxy" httpsProxyDaemonShText);

{
}
