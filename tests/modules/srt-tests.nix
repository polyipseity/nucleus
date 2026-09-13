# tests/modules/srt-tests.nix — Sandbox-runtime (srt) settings and provisioning.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  lockfile = builtins.fromJSON (builtins.readFile ../../src/lockfiles/lockfile.json);
  settings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);

  # === PACKAGE PROVISIONING ===

  test_srt_in_lockfile = assert' (
    builtins.hasAttr "@anthropic-ai/sandbox-runtime" (lockfile.bun or { })
  ) "sandbox-runtime must have a version pin in lockfile.json bun section";

  # === SETTINGS PROVISIONING ===

  test_srt_settings_exists = assert' (builtins.pathExists ../../src/users/default/srt/settings.json) "srt settings.json must exist in src/users/default/srt/";

  test_srt_settings_has_schema = assert' (builtins.pathExists ../../src/users/default/srt/settings.schema.json) "srt settings.schema.json must exist in src/users/default/srt/";

  test_srt_settings_allow_pty = assert' (
    settings.allowPty == true
  ) "srt settings must have allowPty = true";

  test_srt_settings_enable_weaker_network_isolation = assert' (
    settings.enableWeakerNetworkIsolation == true
  ) "srt settings must have enableWeakerNetworkIsolation = true for Go TLS verification";

  test_srt_settings_deny_read_covers_credentials = assert' (
    let
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
  ) "srt denyRead must cover all credential paths";

  test_srt_settings_deny_write_covers_injection = assert' (
    let
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
    settings.network.allowLocalBinding == true
  ) "srt network allowLocalBinding must be true for local dev servers";

  test_srt_settings_network_covers_api_providers = assert' (
    let
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
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "*.github.com"
      "github.com"
    ]
  ) "srt allowedDomains must include *.github.com and github.com";

  test_srt_settings_network_covers_nix_cache = assert' (
    let
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "cache.nixos.org"
      "nix-community.cachix.org"
    ]
  ) "srt allowedDomains must cover nix binary caches";

  test_srt_settings_network_covers_cargo = assert' (
    let
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "static.crates.io"
      "index.crates.io"
    ]
  ) "srt allowedDomains must cover cargo/crates.io endpoints";

  test_srt_settings_network_covers_python = assert' (
    builtins.elem "files.pythonhosted.org" settings.network.allowedDomains
  ) "srt allowedDomains must cover PyPI file downloads";

  test_srt_settings_network_covers_rust = assert' (
    builtins.elem "static.rust-lang.org" settings.network.allowedDomains
  ) "srt allowedDomains must cover rustup downloads";

  test_srt_settings_network_covers_ghcr = assert' (
    let
      allowed = settings.network.allowedDomains;
    in
    builtins.all (d: builtins.elem d allowed) [
      "ghcr.io"
      "github-releases.githubusercontent.com"
      "formulae.brew.sh"
    ]
  ) "srt allowedDomains must cover ghcr.io, GitHub releases CDN, and Homebrew";

  test_srt_settings_network_covers_ollama = assert' (
    builtins.elem "registry.ollama.ai" settings.network.allowedDomains
  ) "srt allowedDomains must cover ollama model registry";

  test_srt_settings_ignore_violations_covers_homebrew = assert' (
    let
      ignores = settings.ignoreViolations."*";
    in
    builtins.all (p: builtins.elem p ignores) [
      "/usr/local"
      "~/Library"
    ]
  ) "srt ignoreViolations must cover Homebrew and macOS app paths";

  test_srt_settings_ignore_violations_comprehensive = assert' (
    let
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
    builtins.elem ".git/hooks" (settings.ignoreViolations.prek or [ ])
  ) "srt ignoreViolations must allow prek to write .git/hooks";

  test_srt_settings_ignore_violations_nix = assert' (
    builtins.elem "/nix/var" (settings.ignoreViolations.nix or [ ])
  ) "srt ignoreViolations must allow nix to access /nix/var";

  allTests = [
    test_srt_in_lockfile
    test_srt_settings_exists
    test_srt_settings_has_schema
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
  ];
in
builtins.seq
  (builtins.deepSeq {
    inherit
      test_srt_in_lockfile
      test_srt_settings_exists
      test_srt_settings_has_schema
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
      ;
  } null)
  {
    success = true;
    message = "All srt settings tests passed";
  }
