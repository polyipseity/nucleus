# tests/modules/srt-tests.nix — Sandbox-runtime (srt) package provisioning and agent wrapping.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  coreModuleText = builtins.readFile ../../src/modules/core.nix;
  homeModuleText = builtins.readFile ../../src/modules/home.nix;
  agentsModuleText = builtins.readFile ../../src/modules/agents.nix;
  initZshText = builtins.readFile ../../src/scripts/shell/init.zsh;
  profilePs1Text = builtins.readFile ../../src/scripts/shell/profile.ps1;
  bunInstallText = builtins.readFile ../../src/scripts/packages/install-bun-packages.sh;

  # === PACKAGE PROVISIONING ===

  test_srt_in_managed_packages = assert' (
    lib.hasInfix "\"sandbox-runtime\" = {" coreModuleText
    && lib.hasInfix "nixpkgs = \"sandbox-runtime\";" coreModuleText
  ) "sandbox-runtime must be declared in managedPackages with nixpkgs attr";

  # srt is provided by nixpkgs on POSIX (managedPackages), NOT by bun.
  # bun install is only used on Windows (Invoke-BunSetup.ps1).
  test_srt_not_in_bun_desired = assert' (
    !lib.hasInfix "'@anthropic-ai/sandbox-runtime'" bunInstallText
  ) "sandbox-runtime must NOT be in POSIX bun desired list (nixpkgs provides it)";

  test_srt_in_lockfile = assert' (
    let
      lockfile = builtins.fromJSON (builtins.readFile ../../src/lockfiles/lockfile.json);
      hasSrt = builtins.hasAttr "@anthropic-ai/sandbox-runtime" (lockfile.bun or { });
    in
    hasSrt
  ) "sandbox-runtime must have a version pin in lockfile.json bun section";

  # === SETTINGS PROVISIONING ===

  test_srt_settings_exists = assert' (builtins.pathExists ../../src/users/default/srt/settings.json) "srt settings.json must exist in src/users/default/srt/";

  test_srt_settings_allow_pty = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
    in
    settings.allowPty == true
  ) "srt settings must have allowPty = true";

  test_srt_settings_enable_weaker_network_isolation = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
    in
    settings.enableWeakerNetworkIsolation == true
  ) "srt settings must have enableWeakerNetworkIsolation = true for Go TLS verification";

  test_srt_settings_deny_read_covers_credentials = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      denyRead = settings.filesystem.denyRead;
    in
    builtins.all (p: builtins.elem p denyRead) [
      "~/.aws"
      "~/.azure"
      "~/.config/gcloud"
      "~/.docker/config.json"
      "~/.env*"
      "~/.kube"
      "~/.npmrc"
      "~/.sops"
      "~/.ssh"
      "~/Library/Keychains"
    ]
  ) "srt denyRead must cover all credential paths (note: ~/.gnupg is in allowWrite for git signing)";

  test_srt_settings_deny_write_covers_injection = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      denyWrite = settings.filesystem.denyWrite;
    in
    builtins.all (p: builtins.elem p denyWrite) [
      ".env"
      ".env.*"
      ".git/config"
      ".git/hooks"
      ".vscode/launch.json"
      ".vscode/tasks.json"
      "~/.bash_profile"
      "~/.bashrc"
      "~/.config/fish"
      "~/.zshenv"
      "~/.zprofile"
      "~/.zshrc"
    ]
  ) "srt denyWrite must cover git hooks, vscode, and shell profiles";

  test_srt_settings_allow_write = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowWrite = settings.filesystem.allowWrite;
    in
    builtins.all (p: builtins.elem p allowWrite) [
      "."
      "/tmp"
      "~/.bun"
      "~/.cache"
      "~/.cargo"
      "~/.cursor"
      "~/.gnupg"
      "~/.local"
      "~/.npm"
      "~/.pi"
      "~/.rustup"
      "~/dev"
    ]
  ) "srt allowWrite must cover project dir, tmp, package caches, XDG dirs, and dev directory";

  test_srt_settings_network_local_binding = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
    in
    settings.network.allowLocalBinding == true
  ) "srt network allowLocalBinding must be true for local dev servers";

  test_srt_settings_network_covers_api_providers = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "api.anthropic.com"
      "api.cline.bot"
      "api.commandcode.ai"
      "api.openai.com"
      "openai.com"
    ]
  ) "srt allowedDomains must cover LLM API providers";

  test_srt_settings_network_covers_github = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "*.github.com"
      "github.com"
    ]
  ) "srt allowedDomains must include *.github.com and github.com";

  test_srt_settings_network_covers_nix_cache = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "cache.nixos.org"
      "nix-community.cachix.org"
    ]
  ) "srt allowedDomains must cover nix binary caches";

  test_srt_settings_network_covers_cargo = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "static.crates.io"
      "index.crates.io"
    ]
  ) "srt allowedDomains must cover cargo/crates.io endpoints";

  test_srt_settings_network_covers_python = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.elem "files.pythonhosted.org" allowed
  ) "srt allowedDomains must cover PyPI file downloads";

  test_srt_settings_network_covers_rust = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.elem "static.rust-lang.org" allowed
  ) "srt allowedDomains must cover rustup downloads";

  test_srt_settings_network_covers_ghcr = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "ghcr.io"
      "github-releases.githubusercontent.com"
      "formulae.brew.sh"
    ]
  ) "srt allowedDomains must cover ghcr.io, GitHub releases CDN, and Homebrew";

  test_srt_settings_network_covers_ollama = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      allowed = settings.network.allowedDomains;
    in
    builtins.elem "registry.ollama.ai" allowed
  ) "srt allowedDomains must cover ollama model registry";

  test_srt_settings_ignore_violations_covers_homebrew = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      ignores = settings.ignoreViolations."*";
    in
    builtins.all (p: builtins.elem p ignores) [
      "/usr/local"
      "~/Library"
    ]
  ) "srt ignoreViolations must cover Homebrew and macOS app paths";

  test_srt_settings_ignore_violations_comprehensive = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      ignores = settings.ignoreViolations."*";
    in
    builtins.all (p: builtins.elem p ignores) [
      "/etc/hosts"
      "/etc/ssl"
      "/nix/store"
      "/private/tmp"
      "/private/var"
      "/System"
      "/usr/bin"
      "/usr/lib"
      "/usr/share"
    ]
  ) "srt ignoreViolations must cover system paths";

  test_srt_settings_ignore_violations_prek = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      prekIgnores = settings.ignoreViolations.prek or [ ];
    in
    builtins.elem ".git/hooks" prekIgnores
  ) "srt ignoreViolations must allow prek to write .git/hooks";

  test_srt_settings_ignore_violations_nix = assert' (
    let
      settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
      nixIgnores = settings.ignoreViolations.nix or [ ];
    in
    builtins.elem "/nix/var" nixIgnores
  ) "srt ignoreViolations must allow nix to access /nix/var";

  test_srt_settings_has_schema = assert' (builtins.pathExists ../../src/users/default/srt/settings.schema.json) "srt settings.schema.json must exist in src/users/default/srt/";

  test_srt_settings_managed_symlink = assert' (
    lib.hasInfix ".srt-settings.json" homeModuleText && lib.hasInfix "writable = true" homeModuleText
  ) "srt settings must be in managedSymlinkPaths with writable = true";

  test_srt_settings_activation = assert' (
    lib.hasInfix "seed-srt-settings" homeModuleText
    && lib.hasInfix "overlay.selectFile" homeModuleText
    && lib.hasInfix "\"srt\" \"settings.json\"" homeModuleText
  ) "srt settings activation must use overlay.selectFile for per-user override support";

  # === AGENT WRAPPING ===

  test_srt_pi_function_zsh = assert' (
    lib.hasInfix "pi()" initZshText
    && lib.hasInfix "srt command pi" initZshText
    && lib.hasInfix "srt (sandbox-runtime) is required" initZshText
  ) "init.zsh must have pi() function with hard-error when srt missing";

  test_srt_pi_unrestricted_zsh = assert' (
    lib.hasInfix "pi-unrestricted()" initZshText && lib.hasInfix "command pi" initZshText
  ) "init.zsh must have pi-unrestricted() function";

  test_srt_pi_function_ps1 = assert' (
    lib.hasInfix "function pi {" profilePs1Text
    && lib.hasInfix "srt command pi" profilePs1Text
    && lib.hasInfix "srt (sandbox-runtime) is required" profilePs1Text
  ) "profile.ps1 must have pi function with hard-error when srt missing";

  test_srt_pi_unrestricted_ps1 = assert' (
    lib.hasInfix "function pi-unrestricted" profilePs1Text && lib.hasInfix "& pi @args" profilePs1Text
  ) "profile.ps1 must have pi-unrestricted function";

  # === DOCUMENTATION ===

  test_srt_policy_documented = assert' (
    lib.hasInfix "Sandbox-runtime (srt) policy" agentsModuleText
    && lib.hasInfix "pi-unrestricted" agentsModuleText
    && lib.hasInfix "cursor" agentsModuleText
  ) "agents.nix must document the srt sandboxing policy";

  test_srt_excludes_cursor = assert' (
    lib.hasInfix "cursor" agentsModuleText && lib.hasInfix "built-in protections" agentsModuleText
  ) "agents.nix must document that cursor is excluded from srt sandboxing";
in
builtins.seq
  (builtins.deepSeq {
    inherit
      test_srt_in_managed_packages
      test_srt_not_in_bun_desired
      test_srt_in_lockfile
      test_srt_settings_exists
      test_srt_settings_allow_pty
      test_srt_settings_enable_weaker_network_isolation
      test_srt_settings_deny_read_covers_credentials
      test_srt_settings_deny_write_covers_injection
      test_srt_settings_allow_write
      test_srt_settings_network_local_binding
      test_srt_settings_network_covers_api_providers
      test_srt_settings_network_covers_github
      test_srt_settings_network_covers_nix_cache
      test_srt_settings_network_covers_cargo
      test_srt_settings_network_covers_python
      test_srt_settings_network_covers_rust
      test_srt_settings_network_covers_ghcr
      test_srt_settings_network_covers_ollama
      test_srt_settings_ignore_violations_covers_homebrew
      test_srt_settings_ignore_violations_comprehensive
      test_srt_settings_ignore_violations_prek
      test_srt_settings_ignore_violations_nix
      test_srt_settings_has_schema
      test_srt_settings_managed_symlink
      test_srt_settings_activation
      test_srt_pi_function_zsh
      test_srt_pi_unrestricted_zsh
      test_srt_pi_function_ps1
      test_srt_pi_unrestricted_ps1
      test_srt_policy_documented
      test_srt_excludes_cursor
      ;
  } null)
  {
    success = true;
    message = "All srt tests passed";
  }
