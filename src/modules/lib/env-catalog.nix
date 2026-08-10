# modules/lib/env-catalog.nix — Centralized environment variable catalog.
#
# This file contains the catalog of all managed environment variables and
# the resolution logic for rendering them per-host.  It internally imports
# managed-paths.nix for PATH-related catalog entries but does NOT re-export
# those bindings — callers should import managed-paths.nix directly for
# PATH-specific needs.
#
# Callers MUST pass `username`.  Do NOT add a fallback chain (no default null,
# no config.home.username fallback, no getEnv "USER" fallback).  Every caller
# has `username` available via specialArgs or as a local binding — use it.
#
# Each catalog entry uses a `values` attrset:
#   { default?, MacBook?, NixOS?, Windows? }
# - `default` applies to any host not explicitly keyed.
# - If a host key is absent AND `default` is absent, the host is not applicable.
# Use: import ./lib/env-catalog.nix { inherit config pkgs lib username hostName; }
# Returns: { catalog, allVars, systemVars, macBookAllVars, resolveValue, ... }
{
  pkgs,
  lib,
  username,
  hostName,
  ...
}:
let
  managedPaths = import ./managed-paths.nix { inherit pkgs; };
  appleSdkEnhanced = import ./apple-sdk-enhanced.nix { inherit pkgs lib; };

  # ── Shared values used by multiple catalog entries ──────────────────

  allUsers = import ./users-registry.nix {
    lib = pkgs.lib;
    repoRoot = ../../..;
    inherit hostName;
  };
  effectiveUsername = username;
  effectiveUser =
    if builtins.hasAttr effectiveUsername allUsers then allUsers.${effectiveUsername} else { };

  resolvedHomeDirectory =
    if hostName == "MacBook" then "/Users/${effectiveUsername}" else "/home/${effectiveUsername}";

  passwordStorePathRaw =
    if
      effectiveUser ? passwordStore
      && effectiveUser.passwordStore ? path
      && effectiveUser.passwordStore.path != ""
    then
      effectiveUser.passwordStore.path
    else
      "~/.password-store";

  passwordStoreDir = builtins.replaceStrings [ "~" ] [ resolvedHomeDirectory ] passwordStorePathRaw;

  passwordStoreDirWindows =
    let
      withProfile =
        builtins.replaceStrings [ "~/" "~" ] [ "%USERPROFILE%\\" "%USERPROFILE%" ]
          passwordStorePathRaw;
    in
    builtins.replaceStrings [ "/" ] [ "\\" ] withProfile;

  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  litellmEndpoint = servicesJSON.litellm.network.default;
  ollamaHost = "${litellmEndpoint.host}:${toString litellmEndpoint.port}";

  # ── Catalog ─────────────────────────────────────────────────────────
  # Each entry:
  #   values:  attrset { default?, MacBook?, NixOS?, Windows? }
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

    # ── Rust test runner (nextest) ────────────────────────────────
    NEXTEST_TEST_THREADS = {
      values = {
        default = "4";
        Windows = "4";
      };
      why = "Limit cargo-nextest test runner concurrency to 4 parallel test threads across all hosts. Set all-process (not just shell) so IDE/debugger integrations also respect the cap.";
    };

    # ── macOS-specific developer toolchain ───────────────────────────
    DEVELOPER_DIR = {
      values = {
        MacBook = "${appleSdkEnhanced}";
      };
      why = "Enhanced apple-sdk with real tool symlinks, so xcrun resolves python3, git, make, etc. without Xcode CLT.";
    };
    SDKROOT = {
      values = {
        MacBook = "${appleSdkEnhanced}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
      };
      why = "Explicit SDKROOT avoids second xcrun invocation when DEVELOPER_DIR is set.";
    };
    LIBRARY_PATH = {
      values = {
        MacBook = "${pkgs.libiconv}/lib";
      };
      why = "Rustup-managed cargo on macOS needs libiconv in LIBRARY_PATH for crates with C deps.";
    };
    NIX_SSL_CERT_FILE = {
      values = {
        default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        Windows = null;
      };
      why = "Nix-managed SSL cert bundle for all processes outside nix-daemon build environments. On NixOS, nix-daemon sets this for its own builds but GUI/CLI tools outside systemd also need it. Not applicable on Windows (no Nix store).";
    };

    # ── Editors ──────────────────────────────────────────────────────
    EDITOR = {
      values = {
        MacBook = "nvim";
        NixOS = null;
        Windows = "nvim";
      };
      why = "Set by programs.neovim.defaultEditor on macOS (nvim activated) and NixOS. Windows Machine-scope DSC sets nvim for all-process parity.";
    };
    VISUAL = {
      values = {
        MacBook = "nvim";
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
        Windows = passwordStoreDirWindows;
      };
      userSpecific = true;
      why = "pass/QtPass/gopass password store location from src/users/<username>/password-store.json. Windows uses literal %USERPROFILE% for User-scope DSC.";
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
        Windows = passwordStoreDirWindows;
      };
      userSpecific = true;
      why = "gopass config override value for password store path from src/users/<username>/password-store.json. Windows uses literal %USERPROFILE% for User-scope DSC.";
    };

    # ── Host identity ────────────────────────────────────────────────
    NUCLEUS_HOST = {
      values = {
        MacBook = "MacBook";
        NixOS = "NixOS";
        Windows = "Windows";
      };
      why = "Canonical host name for VM host-scoping and host-aware consumers. Windows set in system/env.dsc.yml at Machine scope.";
    };

    # ── macOS-specific: repo root ───────────────────────────────────
    NUCLEUS_REPO_ROOT = {
      values = {
        MacBook = builtins.getEnv "NUCLEUS_REPO_ROOT";
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
        MacBook = managedPaths.toShellAppendPath;
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

  # ── Resolve value for an entry on a given host ───────────────────
  # Returns the host-specific value, or `default` if no host key exists, or null
  # if neither the host key nor `default` is present (host not applicable).
  resolveValue =
    name: host:
    let
      entry = catalog.${name};
      userOverride =
        if effectiveUser ? envVars && effectiveUser.envVars ? ${name} then
          effectiveUser.envVars.${name}
        else
          null;
      hostValue =
        if entry.values ? ${host} then
          entry.values.${host}
        else if entry.values ? default then
          entry.values.default
        else
          null;
    in
    if userOverride != null then userOverride else hostValue;

  # ── Current host name (from caller) ──────────────────────────────
  currentHost = hostName;

  # ── Generic filter over attrNames ────────────────────────────────
  # Takes predicate (name, entry -> bool) and target host for value resolution.
  filterAttrsByEntry =
    pred: host:
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
              value = resolveValue name host;
            }
          ]
        else
          [ ]
      ) (builtins.attrNames catalog)
    );

  # ── allVars ───────────────────────────────────────────────────────
  # All vars for current POSIX host, excluding PATH (handled separately
  # via activation/profile).  Host applicability is implicit from resolveValue.
  allVars = filterAttrsByEntry (
    name: entry:
    (!entry ? excludeFromAll || !entry.excludeFromAll) && resolveValue name currentHost != null
  ) currentHost;

  # ── systemVars ───────────────────────────────────────────────────
  # Non-user-specific vars for NixOS environment.variables.
  systemVars = filterAttrsByEntry (
    name: entry: (!entry ? userSpecific || !entry.userSpecific) && resolveValue name "NixOS" != null
  ) "NixOS";

  # ── macBookAllVars ───────────────────────────────────────────────
  # All MacBook vars (both user and non-user) for the gui-env LaunchAgent.
  # PATH is excluded (handled separately via activation/agent scripts).
  macBookAllVars =
    let
      host = "MacBook";
      relevant = builtins.filter (
        name:
        let
          entry = catalog.${name};
        in
        (!entry ? excludeFromAll || !entry.excludeFromAll) && resolveValue name host != null
      ) (builtins.attrNames catalog);
    in
    builtins.concatStringsSep "\n" (
      builtins.map (
        name:
        let
          val = resolveValue name host;
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
        hasMacBookEntry = entry.values ? MacBook || entry.values ? default;
        hasWindowsEntry = entry.values ? Windows || entry.values ? default;
        nixosValue = resolveValue name "NixOS";
        macBookValue = resolveValue name "MacBook";
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
    macBookAllVars
    toJsonManifest
    getAllNixVarNames
    resolveValue
    passwordStoreDir
    currentHost
    ;
}
