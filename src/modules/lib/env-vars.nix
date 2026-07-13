# modules/lib/env-vars.nix — Catalog of managed env vars + helper functions.
#
# This is the single source of truth for every environment variable managed by
# nucleus on macOS and NixOS.  Windows has a separate parallel registry
# (src/hosts/Windows/user/env.dsc.yml); parity is enforced by tests and
# documented in docs/env-variable-registry.md.
#
# Use: import ../lib/env-vars.nix { inherit config pkgs lib; }
# Returns: { catalog, toHomeSessionVariables, toNixOSEnvironment, ... }
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # ── Shared values used by multiple catalog entries ──────────────────

  allUsers = builtins.fromJSON (builtins.readFile ../users.json);
  effectiveUsername = config.home.username;
  effectiveUser =
    if builtins.hasAttr effectiveUsername allUsers then allUsers.${effectiveUsername} else { };

  resolvedHomeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${effectiveUsername}" else "/home/${effectiveUsername}";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else
      "${resolvedHomeDirectory}/.password-store";

  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.prek
      pkgs.uv
    ];
  };

  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  litellmEndpoint = servicesJSON.litellm.network.default;
  ollamaHost = "${litellmEndpoint.host}:${toString litellmEndpoint.port}";

  # ── Catalog ─────────────────────────────────────────────────────────
  # Each entry:
  #   value:   string | null  (null = set externally, e.g. EDITOR)
  #   scope:   "all-process" | "shell-only"
  #   hosts:   list of OS names this applies to
  #   why:     inline justification
  #   override: attrset { macOS = ..., NixOS = ... } for per-OS overrides
  #   excludeFromLaunchctl: true for shell-only vars (default false)
  catalog = {
    # ── Shell-only: Nix LLVM paths stay out of GUI env on macOS ─────
    CC = {
      value = "${pkgs.llvmPackages.clang}/bin/clang";
      scope = "shell-only";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery.";
    };
    CXX = {
      value = "${pkgs.llvmPackages.clang}/bin/clang++";
      scope = "shell-only";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery.";
    };
    LD = {
      value = "${pkgs.llvmPackages.lld}/bin/ld.lld";
      scope = "shell-only";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery.";
    };

    # ── macOS-specific developer toolchain (all-process) ─────────────
    DEVELOPER_DIR = {
      value = "${pkgs.apple-sdk}";
      scope = "all-process";
      hosts = [ "macOS" ];
      why = "Without Xcode CLT, xcrun needs DEVELOPER_DIR pointing at Nix apple-sdk to discover SDK without installation dialog.";
    };
    SDKROOT = {
      value = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
      scope = "all-process";
      hosts = [ "macOS" ];
      why = "Explicit SDKROOT avoids second xcrun invocation when DEVELOPER_DIR is set.";
    };
    LIBRARY_PATH = {
      value = "${pkgs.libiconv}/lib";
      scope = "all-process";
      hosts = [ "macOS" ];
      why = "Rustup-managed cargo on macOS needs libiconv in LIBRARY_PATH for crates with C deps.";
    };
    NIX_SSL_CERT_FILE = {
      value = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      scope = "all-process";
      hosts = [ "macOS" ];
      why = "Nix-managed SSL cert bundle for processes outside Nix build environments.";
    };

    # ── Editors (all-process) ────────────────────────────────────────
    EDITOR = {
      value = null;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      override = {
        macOS = "nvim";
      };
      why = "Set by programs.neovim.defaultEditor. macOS LaunchAgent hardcodes nvim for GUI domain.";
    };
    VISUAL = {
      value = null;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      override = {
        macOS = "nvim";
      };
      why = "Set by programs.neovim.defaultEditor. macOS LaunchAgent hardcodes nvim for GUI domain.";
    };

    # ── OpenCode (all-process) ───────────────────────────────────────
    OPENCODE_DISABLE_AUTOUPDATE = {
      value = "true";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Managed environment pins OpenCode; auto-updates introduce version skew.";
    };

    # ── AI / Ollama (all-process) ────────────────────────────────────
    OLLAMA_HOST = {
      value = ollamaHost;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Point clients at LiteLLM proxy instead of Ollama directly.";
    };

    # Ollama runtime tunables (NixOS systemd service only — macOS uses
    # model manifest defaults instead of launchd env overrides).
    OLLAMA_FLASH_ATTENTION = {
      value = "1";
      scope = "all-process";
      hosts = [ "NixOS" ];
      why = "Enable flash attention to reduce attention memory overhead.";
    };
    OLLAMA_CONTEXT_LENGTH = {
      value = "32768";
      scope = "all-process";
      hosts = [ "NixOS" ];
      why = "Set 32k token default context window so models that default to 2k/4k do not silently truncate.";
    };
    OLLAMA_KV_CACHE_TYPE = {
      value = "q4_0";
      scope = "all-process";
      hosts = [ "NixOS" ];
      why = "Compress KV cache with 4-bit quantisation to halve RAM footprint.";
    };

    # ── Password store (all-process) ─────────────────────────────────
    PASSWORD_STORE_DIR = {
      value = passwordStoreDir;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "pass/QtPass/gopass password store location from users.json.";
    };
    GOPASS_CONFIG_COUNT = {
      value = "1";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "gopass config override count for password store path.";
    };
    GOPASS_CONFIG_KEY_1 = {
      value = "path";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "gopass config override key for password store path.";
    };
    GOPASS_CONFIG_VALUE_1 = {
      value = passwordStoreDir;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "gopass config override value for password store path.";
    };

    # ── Fallback toolchain (all-process) ────────────────────────────
    NUCLEUS_DEFAULT_DEV_BIN = {
      value = "${defaultDevTools}/bin";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Fallback toolchain bin dir for repos without direnv/Nix devShell.";
    };
    NUCLEUS_DEFAULT_DEV_ENV = {
      value = "1";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Flag that fallback toolchain is configured.";
    };

    # ── Host identity (all-process, OS-specific) ────────────────────
    NUCLEUS_HOST = {
      value = null;
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      override = {
        macOS = "MacBook";
        NixOS = "NixOS";
      };
      why = "Canonical host name for VM host-scoping and host-aware consumers.";
    };

    # ── macOS-specific: repo root (all-process) ─────────────────────
    NUCLEUS_REPO_ROOT = {
      value = builtins.getEnv "NUCLEUS_REPO_ROOT";
      scope = "all-process";
      hosts = [ "macOS" ];
      why = "Repo root for out-of-store symlinks. Captured at eval time from apply.sh export.";
    };

    # ── Starship prompt (all-process) ───────────────────────────────
    STARSHIP_CACHE = {
      value = "${resolvedHomeDirectory}/.cache/starship";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Starship computed-state cache directory.";
    };
    STARSHIP_CONFIG = {
      value = "${resolvedHomeDirectory}/.config/starship.toml";
      scope = "all-process";
      hosts = [
        "macOS"
        "NixOS"
      ];
      why = "Starship config path. POSIX uses out-of-store symlink; Windows sets via env.dsc.yml.";
    };
  };

  # ── Resolve value for an entry on a given OS ─────────────────────
  # Returns null if entry is not applicable to the OS.
  resolveValue =
    name: os:
    let
      entry = catalog.${name};
      hasOs = builtins.elem os entry.hosts;
      hasOverride = entry ? override && entry.override ? ${os};
    in
    if !hasOs then
      null
    else if hasOverride then
      entry.override.${os}
    else
      entry.value;

  # ── Determine current OS name ────────────────────────────────────
  currentOs = if pkgs.stdenv.isDarwin then "macOS" else "NixOS";

  # ── Generic filter over attrNames ────────────────────────────────
  # Takes predicate (name, entry -> bool) and target OS for value resolution.
  filterAttrsByEntry =
    pred: os:
    builtins.listToAttrs (
      builtins.concatMap (
        name:
        let
          entry = catalog.${name};
        in
        if pred name entry then
          [
            {
              inherit name;
              value = resolveValue name os;
            }
          ]
        else
          [ ]
      ) (builtins.attrNames catalog)
    );

  # ── toHomeSessionVariables ───────────────────────────────────────
  # All vars (including shell-only) for current POSIX host, excluding
  # null-valued ones (set outside home-manager, e.g. EDITOR).
  toHomeSessionVariables = filterAttrsByEntry (
    name: entry: builtins.elem currentOs entry.hosts && resolveValue name currentOs != null
  ) currentOs;

  # ── toNixOSEnvironment ───────────────────────────────────────────
  # All-process vars applicable to NixOS for environment.variables.
  toNixOSEnvironment = filterAttrsByEntry (
    name: entry:
    builtins.elem "NixOS" entry.hosts
    && entry.scope == "all-process"
    && resolveValue name "NixOS" != null
  ) "NixOS";

  # ── toLaunchctlScript ────────────────────────────────────────────
  # Shell script for macOS gui-env LaunchAgent (all-process macOS vars).
  toLaunchctlScript =
    let
      os = "macOS";
      relevant = builtins.filter (
        name:
        let
          entry = catalog.${name};
        in
        builtins.elem os entry.hosts
        && entry.scope == "all-process"
        && (!entry ? excludeFromLaunchctl || !entry.excludeFromLaunchctl)
        && resolveValue name os != null
      ) (builtins.attrNames catalog);
    in
    builtins.concatStringsSep "\n" (
      builtins.map (
        name:
        let
          val = resolveValue name os;
        in
        if val != null then "/bin/launchctl setenv ${name} ${val}" else ""
      ) relevant
    );

  # ── toNixOSServiceEnv ────────────────────────────────────────────
  # OLLAMA_* vars for services.ollama.environmentVariables.
  toNixOSServiceEnv = filterAttrsByEntry (
    name: entry:
    builtins.elem "NixOS" entry.hosts
    && entry.scope == "all-process"
    && lib.strings.hasPrefix "OLLAMA_" name
    && name != "OLLAMA_HOST"
    && resolveValue name "NixOS" != null
  ) "NixOS";

  # ── Introspection for Windows parity tests ───────────────────────
  toJsonManifest = builtins.toJSON (
    builtins.map (
      name:
      let
        entry = catalog.${name};
      in
      {
        inherit name;
        scope = entry.scope;
        why = entry.why;
        hasNixOsEntry = builtins.elem "NixOS" entry.hosts;
        hasMacOsEntry = builtins.elem "macOS" entry.hosts;
        nixosValue = resolveValue name "NixOS";
        macosValue = resolveValue name "macOS";
      }
    ) (builtins.attrNames catalog)
  );

  getAllNixVarNames = builtins.attrNames catalog;
in
{
  inherit
    catalog
    toHomeSessionVariables
    toNixOSEnvironment
    toLaunchctlScript
    toNixOSServiceEnv
    toJsonManifest
    getAllNixVarNames
    resolveValue
    defaultDevTools
    passwordStoreDir
    currentOs
    ;
}
