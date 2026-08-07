# tests/integration/repo-root-file-tests.nix — Verify /etc/nucleus/repo-root wiring on POSIX hosts.

let
  inherit (import ../lib.nix) assert' containsRegex;

  repoRootFileModuleText = builtins.readFile ../../src/modules/repo-root-file.nix;
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  nixosDefaultText = builtins.readFile ../../src/hosts/NixOS/default.nix;
  posixSecurityText = builtins.readFile ../../src/modules/posix-security.nix;
  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;

  test_repo_root_file_module = assert' (
    containsRegex "environment\.etc\.\"nucleus/repo-root\"" repoRootFileModuleText
    && containsRegex "builtins\.getEnv \"NUCLEUS_REPO_ROOT\"" repoRootFileModuleText
  ) "repo-root-file.nix must materialize /etc/nucleus/repo-root from NUCLEUS_REPO_ROOT";

  test_macbook_imports_repo_root_file = assert' (
    containsRegex "\.\./\.\./modules/repo-root-file\.nix" macbookDefaultText
  ) "MacBook must import repo-root-file.nix";

  test_nixos_imports_repo_root_file = assert' (
    containsRegex "\.\./\.\./modules/repo-root-file\.nix" nixosDefaultText
  ) "NixOS must import repo-root-file.nix";

  test_sudo_preserves_nucleus_repo_root = assert' (
    containsRegex "env_keep.*NUCLEUS_REPO_ROOT" posixSecurityText
  ) "posix-security.nix must preserve NUCLEUS_REPO_ROOT through sudo";

  test_derive_repo_root_reads_system_file = assert' (
    containsRegex "/etc/nucleus/repo-root" libShText
    && containsRegex "NUCLEUS_REPO_ROOT_SYSTEM_FILE" libShText
  ) "derive_repo_root must read /etc/nucleus/repo-root with test override";

  allTests = [
    test_repo_root_file_module
    test_macbook_imports_repo_root_file
    test_nixos_imports_repo_root_file
    test_sudo_preserves_nucleus_repo_root
    test_derive_repo_root_reads_system_file
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} repo-root-file tests passed";
}
