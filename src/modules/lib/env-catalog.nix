# modules/lib/env-catalog.nix — Centralized environment variable catalog.
#
# This file contains the catalog of all managed environment variables and
# the resolution logic for rendering them per-OS.  It internally imports
# managed-paths.nix for PATH-related catalog entries but does NOT re-export
# those bindings — callers should import managed-paths.nix directly for
# PATH-specific needs.
#
# Callers MUST pass `username`.  Do NOT add a fallback chain (no default null,
# no config.home.username fallback, no getEnv "USER" fallback).  Every caller
# has `username` available via specialArgs or as a local binding — use it.
#
# Each catalog entry uses a `values` attrset:
#   { default?, macOS?, NixOS?, Windows? }
# - `default` applies to any OS not explicitly keyed.
# - If an OS key is absent AND `default` is absent, the OS is not applicable.
# Use: import ./lib/env-catalog.nix { inherit config pkgs lib username; }
# Returns: { catalog, allVars, systemVars, macOSAllVars, resolveValue, ... }
{
  config,
  pkgs,
  lib,
  username,
  ...
}:
let
  managedPaths = import ./managed-paths.nix { inherit pkgs; };
  appleSdkTools = import ./apple-sdk-tools.nix { inherit pkgs; };
  appleSdkEnhanced = import ./apple-sdk-enhanced.nix { inherit pkgs lib; };

  # ── Shared values used by multiple catalog entries ──────────────────

  allUsers = builtins.fromJSON (builtins.readFile ../users.json);
  effectiveUsername = username;
  effectiveUser =
    if builtins.hasAttr effectiveUsername allUsers then allUsers.${effectiveUsername} else { };

  resolvedHomeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${effectiveUsername}" else "/home/${effectiveUsername}";

  passwordStoreDir =
    if effectiveUser ? passwordStore && effectiveUser.passwordStore ? path then
      builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] effectiveUser.passwordStore.path
    else
      "${resolvedHomeDirectory}/.password-store";

  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  litellmEndpoint = servicesJSON.litellm.network.default;
  ollamaHost = "${litellmEndpoint.host}:${toString litellmEndpoint.port}";

  # ── Catalog ─────────────────────────────────────────────────────────
  # Each entry:
  #   values:  attrset { default?, macOS?, NixOS?, Windows? }
  #   why:     inline justification
  #   userSpecific: true if the value depends on the logged-in user (default false)
  catalog = {
    # ── Compiler toolchain ──────────────────────────────────────────
    CC = {
      values = {
        default = "${pkgs.llvmPackages.clang}/bin/clang";
        Windows = "clang";
      };
      why = "Nix CC for native builds \u2014 all-process on all hosts. On Windows, resolved from PATH by Machine-scope DSC.";
    };
    CXX = {
      values = {
        default = "${pkgs.llvmPackages.clang}/bin/clang++";
        Windows = "clang++";
      };
      why = "Nix CXX for native builds \u2014 all-process on all hosts. On Windows, resolved from PATH by Machine-scope DSC.";
    };
    LD = {
      values = {
        default = "${pkgs.llvmPackages.lld}/bin/ld.lld";
        Windows = "ld.lld";
      };
      why = "Nix LD for native builds \u2014 all-process on all hosts. On Windows, resolved from PATH by Machine-scope DSC.";
    };

    # ── Compiler caching (sccache) ──────────────────────────────────
    CMAKE_C_COMPILER_LAUNCHER = {
      values = {
        default = "${pkgs.sccache}/bin/sccache";
        Windows = "sccache";
      };
      why = "Wrap CMake C compilation through sccache for cross-host C/C++ compiler caching. On Windows, resolved from PATH via Machine-scope DSC.";
    };
    CMAKE_CXX_COMPILER_LAUNCHER = {
      values = {
        default = "${pkgs.sccache}/bin/sccache";
        Windows = "sccache";
      };
      why = "Wrap CMake C++ compilation through sccache for cross-host C/C++ compiler caching. On Windows, resolved from PATH via Machine-scope DSC.";
    };
    SCCACHE_CACHE_SIZE = {
      values = {
        default = "10000000000";
        Windows = "10000000000";
      };
      why = "10 GB sccache cache cap across all hosts. Value is exactly 10 * 10^9 bytes (10 GB). On Windows, set via Machine-scope DSC.";
    };
    SCCACHE_IDLE_TIMEOUT = {
      values = {
        default = "600";
        Windows = "600";
      };
      why = "sccache server idle timeout: 10 minutes. Server auto-exits after this idle period. On Windows, set via Machine-scope DSC.";
    };
    SCCACHE_IGNORE_SERVER_IO_ERROR = {
      values = {
        default = "0";
        Windows = "0";
      };
      why = "Hard-fail on sccache server I/O errors (default). Explicitly set to 0 to ensure builds fail fast when sccache is broken, preventing silent cache misses.";
    };
    SCCACHE_BASEDIRS = {
      values = {
        default = "/Users/${username}";
        NixOS = "/home/${username}";
        Windows = "%USERPROFILE%";
      };
      userSpecific = true;
      why = "Normalise home-directory prefix in sccache cache keys so the same project checked out under different parent paths produces cache hits. Set per-user because the value depends on the logged-in user's home directory.";
    };

    # ── macOS-specific developer toolchain ───────────────────────────
    DEVELOPER_DIR = {
      values = {
        macOS = "${appleSdkEnhanced}";
      };
      why = "Enhanced apple-sdk with real tool symlinks, so xcrun resolves python3, git, make, etc. without Xcode CLT.";
    };
    SDKROOT = {
      values = {
        macOS = "${appleSdkEnhanced}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
      };
      why = "Explicit SDKROOT avoids second xcrun invocation when DEVELOPER_DIR is set.";
    };
    LIBRARY_PATH = {
      values = {
        macOS = "${pkgs.libiconv}/lib";
      };
      why = "Rustup-managed cargo on macOS needs libiconv in LIBRARY_PATH for crates with C deps.";
    };
    NIX_SSL_CERT_FILE = {
      values = {
        default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      why = "Nix-managed SSL cert bundle for all processes outside nix-daemon build environments. On NixOS, nix-daemon sets this for its own builds but GUI/CLI tools outside systemd also need it. Not applicable on Windows (no Nix store).";
    };

    # ── Editors ──────────────────────────────────────────────────────
    EDITOR = {
      values = {
        macOS = "nvim";
        NixOS = null;
        Windows = "nvim";
      };
      why = "Set by programs.neovim.defaultEditor on macOS (nvim activated) and NixOS. Windows Machine-scope DSC sets nvim for all-process parity.";
    };
    VISUAL = {
      values = {
        macOS = "nvim";
        NixOS = null;
        Windows = "nvim";
      };
      why = "Set by programs.neovim.defaultEditor on macOS (nvim activated) and NixOS. Windows Machine-scope DSC sets nvim for all-process parity.";
    };

    # ── OpenCode ─────────────────────────────────────────────────────
    OPENCODE_DISABLE_AUTOUPDATE = {
      values = {
        default = "true";
      };
      why = "Managed environment pins OpenCode; auto-updates introduce version skew. Now set on Windows too via Machine-scope DSC.";
    };

    # ── AI / Ollama ──────────────────────────────────────────────────
    OLLAMA_HOST = {
      values = {
        default = ollamaHost;
      };
      why = "Point CLI clients at LiteLLM proxy (127.0.0.1:4000) on all OSes instead of Ollama directly.";
    };

    # Ollama runtime tunables (all hosts).
    # Set on all OSes for consistent inference behaviour.
    OLLAMA_FLASH_ATTENTION = {
      values = {
        default = "1";
      };
      why = "Enable flash attention to reduce attention memory overhead on all hosts.";
    };
    OLLAMA_CONTEXT_LENGTH = {
      values = {
        default = "32768";
      };
      why = "Set 32k token default context window so models that default to 2k/4k do not silently truncate on any host.";
    };
    OLLAMA_KV_CACHE_TYPE = {
      values = {
        default = "q4_0";
      };
      why = "Compress KV cache with 4-bit quantisation to halve RAM footprint on all hosts.";
    };

    # ── Password store ───────────────────────────────────────────────
    PASSWORD_STORE_DIR = {
      values = {
        default = passwordStoreDir;
        Windows = "%USERPROFILE%\\dev\\monorepo-private\\self\\passwords";
      };
      userSpecific = true;
      why = "pass/QtPass/gopass password store location from users.json. Windows uses literal %USERPROFILE% for User-scope DSC.";
    };
    GOPASS_CONFIG_COUNT = {
      values = {
        default = "1";
      };
      userSpecific = true;
      why = "gopass config override count for password store path.";
    };
    GOPASS_CONFIG_KEY_1 = {
      values = {
        default = "path";
      };
      userSpecific = true;
      why = "gopass config override key for password store path.";
    };
    GOPASS_CONFIG_VALUE_1 = {
      values = {
        default = passwordStoreDir;
        Windows = "%USERPROFILE%\\dev\\monorepo-private\\self\\passwords";
      };
      userSpecific = true;
      why = "gopass config override value for password store path. Windows uses literal %USERPROFILE% for User-scope DSC.";
    };

    # ── Host identity ────────────────────────────────────────────────
    NUCLEUS_HOST = {
      values = {
        macOS = "MacBook";
        NixOS = "NixOS";
        Windows = "Windows";
      };
      why = "Canonical host name for VM host-scoping and host-aware consumers. Windows set in system/env.dsc.yml at Machine scope.";
    };

    # ── macOS-specific: repo root ───────────────────────────────────
    NUCLEUS_REPO_ROOT = {
      values = {
        macOS = builtins.getEnv "NUCLEUS_REPO_ROOT";
      };
      why = "Repo root for out-of-store symlinks. Baked into store script at build time from apply.sh; activation hook overrides for repo-move edge case.";
    };

    # ── macOS GUI environment PATH (append-only; user-specific) ──
    # PATH at runtime is (system default) with managed dirs prepended before and
    # appended after.  This catalog entry holds only the append portion — the
    # prepend portion is handled in guiEnvAgent and gui-env-path in macos.nix.
    # Set by gui-env-path (activation) and gui-env (login agent) in macos.nix.
    PATH = {
      values = {
        macOS = managedPaths.toShellAppendPath;
      };
      excludeFromAll = true;
      userSpecific = true;
      why = "Managed PATH (append portion) for macOS GUI apps. All managed dirs are appended to avoid shadowing system executables. Propagated via gui-env-path activation step (launchctl setenv + launchctl config user path) and the one-shot gui-env LaunchAgent at login.";
    };

    # ── Starship prompt ─────────────────────────────────────────────
    STARSHIP_CACHE = {
      values = {
        default = "${resolvedHomeDirectory}/.cache/starship";
        Windows = "%USERPROFILE%\\.cache\\starship";
      };
      userSpecific = true;
      why = "Starship computed-state cache directory. Windows uses literal %USERPROFILE%.";
    };
    STARSHIP_CONFIG = {
      values = {
        default = "${resolvedHomeDirectory}/.config/starship.toml";
        Windows = "%USERPROFILE%\\.config\\starship.toml";
      };
      userSpecific = true;
      why = "Starship config path. POSIX uses out-of-store symlink. Windows uses literal %USERPROFILE%.";
    };

    # ── Cross-OS compatibility ──────────────────────────────────────
    HOME = {
      values = {
        Windows = "%USERPROFILE%";
      };
      userSpecific = true;
      why = "Cross-OS parity: Unix-heritage tools (git, ssh, curl) expect HOME. Windows doesn't set HOME by default.";
    };
    NIX_PATH = {
      values = {
        Windows = "nixpkgs=flake:nixpkgs";
      };
      why = "Cross-OS parity: nixpkgs flake lookup via <nixpkgs> in Nix expressions.";
    };
  };

  # ── Resolve value for an entry on a given OS ─────────────────────
  # Returns the OS-specific value, or `default` if no OS key exists, or null
  # if neither the OS key nor `default` is present (OS not applicable).
  resolveValue =
    name: os:
    let
      entry = catalog.${name};
      userOverride =
        if effectiveUser ? envVars && effectiveUser.envVars ? ${name} then
          effectiveUser.envVars.${name}
        else
          null;
      osValue =
        if entry.values ? ${os} then
          entry.values.${os}
        else if entry.values ? default then
          entry.values.default
        else
          null;
    in
    if userOverride != null then userOverride else osValue;

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

  # ── allVars ───────────────────────────────────────────────────────
  # All vars for current POSIX host, excluding PATH (handled separately
  # via activation/profile).  OS applicability is implicit from resolveValue.
  allVars = filterAttrsByEntry (
    name: entry:
    (!entry ? excludeFromAll || !entry.excludeFromAll) && resolveValue name currentOs != null
  ) currentOs;

  # ── systemVars ───────────────────────────────────────────────────
  # Non-user-specific vars for NixOS environment.variables.
  systemVars = filterAttrsByEntry (
    name: entry: (!entry ? userSpecific || !entry.userSpecific) && resolveValue name "NixOS" != null
  ) "NixOS";

  # ── macOSAllVars ─────────────────────────────────────────────────
  # All macOS vars (both user and non-user) for the gui-env LaunchAgent.
  # PATH is excluded (handled separately via activation/agent scripts).
  macOSAllVars =
    let
      os = "macOS";
      relevant = builtins.filter (
        name:
        let
          entry = catalog.${name};
        in
        (!entry ? excludeFromAll || !entry.excludeFromAll) && resolveValue name os != null
      ) (builtins.attrNames catalog);
    in
    builtins.concatStringsSep "\n" (
      builtins.map (
        name:
        let
          val = resolveValue name os;
        in
        if val != null then "/bin/launchctl setenv ${name} ${lib.strings.escapeShellArg val}" else ""
      ) relevant
    );

  # ── Introspection for Windows parity tests ───────────────────────
  toJsonManifest = builtins.toJSON (
    builtins.map (
      name:
      let
        entry = catalog.${name};
      in
      {
        inherit name;
        userSpecific = entry ? userSpecific && entry.userSpecific;
        why = entry.why;
        hasNixOsEntry = entry.values ? NixOS || entry.values ? default;
        hasMacOsEntry = entry.values ? macOS || entry.values ? default;
        hasWindowsEntry = entry.values ? Windows || entry.values ? default;
        nixosValue = resolveValue name "NixOS";
        macosValue = resolveValue name "macOS";
        windowsValue = resolveValue name "Windows";
      }
    ) (builtins.attrNames catalog)
  );

  getAllNixVarNames = builtins.attrNames catalog;
in
{
  inherit
    appleSdkEnhanced
    catalog
    allVars
    systemVars
    macOSAllVars
    toJsonManifest
    getAllNixVarNames
    resolveValue
    passwordStoreDir
    currentOs
    ;
}
