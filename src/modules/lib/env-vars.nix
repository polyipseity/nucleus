# modules/lib/env-vars.nix — Single source of truth for every env var on all hosts.
#
# Callers MUST pass `username`.  Do NOT add a fallback chain (no default null,
# no config.home.username fallback, no getEnv "USER" fallback).  Every caller
# has `username` available via specialArgs or as a local binding — use it.
#
# Each catalog entry uses a `values` attrset:
#   { default?, macOS?, NixOS?, Windows? }
# - `default` applies to any OS not explicitly keyed.
# - If an OS key is absent AND `default` is absent, the OS is not applicable.
# - `scope` defaults to "all-process".  Only set explicitly for "shell-only".
#
# Use: import ./lib/env-vars.nix { inherit config pkgs lib username; }
# Returns: { catalog, toHomeSessionVariables, toNixOSSystemEnvironment, ... }
{
  config,
  pkgs,
  lib,
  username,
  ...
}:
let
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

  # ── PATH components ─────────────────────────────────────────────────
  # Managed PATH directories split into prepend (before system default) and
  # append (after system default) groups.  Each consumer renders these as
  # platform-appropriate PATH strings.
  # Prepend: user-scope package manager bin directories.
  # Append: empty for now — reserved for future use.
  pathComponents = {
    prepend = [
      ".bun/bin"
      ".cargo/bin"
      ".local/bin"
    ];
    append = [ ];
  };

  # ── Helper: render managed PATH parts from pathComponents ──────────
  # Returns a colon-joined string of managed user-scope bin dirs.
  # Contains only the pathComponents (prepend + append), no system default.
  # Callers prepend/append these to the actual PATH at runtime so the system
  # default is preserved dynamically.
  # NOTE: Returns only managed PATH components — callers must combine with
  # the runtime system PATH (prepend + runtime + append).
  toLaunchctlPATH =
    let
      homePrefix = "$HOME";
      prependStr = builtins.concatStringsSep ":" (map (p: "${homePrefix}/${p}") pathComponents.prepend);
      appendStr = builtins.concatStringsSep ":" (map (p: "${homePrefix}/${p}") pathComponents.append);
      components = builtins.filter (s: s != "") [
        (if pathComponents.prepend != [ ] then prependStr else "")
        (if pathComponents.append != [ ] then appendStr else "")
      ];
    in
    builtins.concatStringsSep ":" components;

  # ── Helper: render NixOS PATH from pathComponents ──────────────────
  # Returns a list of absolute directory paths for NixOS
  # environment.variables.PATH.  NixOS joins lists with `:`, so this
  # returns a list rather than a colon-joined string.
  # Contains only the managed pathComponents (prepend + append).  The NixOS
  # caller uses mkBefore so system directories are preserved dynamically.
  # NOTE: Returns only managed PATH components — callers must combine with
  # the runtime system PATH (prepend + runtime + append).
  toNixOSPath =
    let
      homePrefix = resolvedHomeDirectory;
      prependDirs = map (p: "${homePrefix}/${p}") pathComponents.prepend;
      appendDirs = map (p: "${homePrefix}/${p}") pathComponents.append;
    in
    prependDirs ++ appendDirs;

  # ── Helper: render Windows user PATH string from pathComponents ────
  # Returns a semicolon-joined string with %USERPROFILE%-prefixed paths
  # for parity documentation and test consumption.  Not consumed at
  # runtime on Windows (Sync-UserPath.ps1 hardcodes the values since
  # Nix isn't available during apply).
  # NOTE: Returns only managed PATH components — callers must combine with
  # the runtime system PATH.
  toWindowsUserPathString =
    let
      homePrefix = "%USERPROFILE%";
      prependDirs = map (p: "${homePrefix}\\${p}") pathComponents.prepend;
      appendDirs = map (p: "${homePrefix}\\${p}") pathComponents.append;
    in
    builtins.concatStringsSep ";" (prependDirs ++ appendDirs);

  # ── Catalog ─────────────────────────────────────────────────────────
  # Each entry:
  #   values:  attrset { default?, macOS?, NixOS?, Windows? }
  #   scope:   "all-process" (default) | "shell-only"
  #   why:     inline justification
  #   excludeFromLaunchctl: true for shell-only vars (default false)
  #   userSpecific: true if the value depends on the logged-in user (default false)
  catalog = {
    # ── Compiler toolchain (all-process) ────────────────────────────
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

    # ── macOS-specific developer toolchain (all-process) ─────────────
    DEVELOPER_DIR = {
      values = {
        macOS = "${pkgs.apple-sdk}";
      };
      why = "Without Xcode CLT, xcrun needs DEVELOPER_DIR pointing at Nix apple-sdk to discover SDK without installation dialog.";
    };
    SDKROOT = {
      values = {
        macOS = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
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

    # ── Editors (all-process) ────────────────────────────────────────
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

    # ── OpenCode (all-process) ───────────────────────────────────────
    OPENCODE_DISABLE_AUTOUPDATE = {
      values = {
        default = "true";
      };
      why = "Managed environment pins OpenCode; auto-updates introduce version skew. Now set on Windows too via Machine-scope DSC.";
    };

    # ── AI / Ollama (all-process) ────────────────────────────────────
    OLLAMA_HOST = {
      values = {
        default = ollamaHost;
      };
      why = "Point CLI clients at LiteLLM proxy (127.0.0.1:4000) on all OSes instead of Ollama directly.";
    };

    # Ollama runtime tunables (all-process, all hosts).
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

    # ── Password store (all-process) ─────────────────────────────────
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

    # ── Fallback toolchain (all-process) ────────────────────────────
    NUCLEUS_DEFAULT_DEV_BIN = {
      values = {
        default = "${defaultDevTools}/bin";
        Windows = "%USERPROFILE%\\scoop\\shims";
      };
      userSpecific = true;
      why = "Fallback toolchain bin dir for repos without direnv/Nix devShell. Windows uses Scoop shims path.";
    };
    NUCLEUS_DEFAULT_DEV_ENV = {
      values = {
        default = "1";
      };
      userSpecific = true;
      why = "Flag that fallback toolchain is configured.";
    };

    # ── Host identity (all-process) ──────────────────────────────────
    NUCLEUS_HOST = {
      values = {
        macOS = "MacBook";
        NixOS = "NixOS";
        Windows = "Windows";
      };
      why = "Canonical host name for VM host-scoping and host-aware consumers. Windows set in system/env.dsc.yml at Machine scope.";
    };

    # ── macOS-specific: repo root (all-process) ─────────────────────
    NUCLEUS_REPO_ROOT = {
      values = {
        macOS = builtins.getEnv "NUCLEUS_REPO_ROOT";
      };
      excludeFromLaunchctl = true;
      why = "Repo root for out-of-store symlinks. Captured at eval time from apply.sh export. Excluded from gui-env-system agent because builtins.getEnv returns empty string when built outside apply.sh; set via activation script instead.";
    };

    # ── macOS GUI environment PATH (user-specific) ─────────────────
    PATH = {
      values = {
        macOS = toLaunchctlPATH;
      };
      excludeFromSessionVariables = true;
      excludeFromLaunchctl = true;
      userSpecific = true;
      why = "Managed PATH (managed dirs only, no system default) for macOS GUI apps. The managed dirs are prepended to the actual PATH at runtime by guiEnvActivationPathAndRepoRoot (activation) and gui-env-system (login agent) — this avoids hardcoding system defaults. Excluded from shell sessionVariables (shell domain gets prepend from home.sessionPath + system PATH from nix-darwin set-environment) and from launchctl agents (handled dynamically by the activation/login scripts).";
    };

    # ── Starship prompt (all-process) ───────────────────────────────
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

    # ── Cross-OS compatibility (all-process) ────────────────────────
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

  # ── Default scope helper ─────────────────────────────────────────
  getScope = entry: if entry ? scope then entry.scope else "all-process";

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

  # ── getScope ─────────────────────────────────────────────────────
  # Returns entry scope, defaulting to "all-process".
  # Defined here for access by helper functions below.

  # ── toHomeSessionVariables ───────────────────────────────────────
  # All vars for current POSIX host, excluding null-valued ones (set
  # outside home-manager, e.g. EDITOR).  OS applicability is implicit
  # from resolveValue.
  toHomeSessionVariables = filterAttrsByEntry (
    name: entry:
    (!entry ? excludeFromSessionVariables || !entry.excludeFromSessionVariables)
    && resolveValue name currentOs != null
  ) currentOs;

  # ── toNixOSSystemEnvironment ─────────────────────────────────────
  # All-process, non-user-specific vars for NixOS environment.variables.
  toNixOSSystemEnvironment = filterAttrsByEntry (
    name: entry:
    getScope entry == "all-process"
    && (!entry ? userSpecific || !entry.userSpecific)
    && resolveValue name "NixOS" != null
  ) "NixOS";

  # ── toLaunchctlScript ────────────────────────────────────────────
  # Shell script for macOS gui-env-system LaunchAgent (all-process, non-user-specific macOS vars).
  toLaunchctlScript =
    let
      os = "macOS";
      relevant = builtins.filter (
        name:
        let
          entry = catalog.${name};
        in
        getScope entry == "all-process"
        && (!entry ? excludeFromLaunchctl || !entry.excludeFromLaunchctl)
        && (!entry ? userSpecific || !entry.userSpecific)
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

  # ── toUserLaunchctlScript ────────────────────────────────────────
  # Shell script for macOS gui-env-user LaunchAgent (user-specific macOS vars).
  # User-specific vars (PASSWORD_STORE_DIR, STARSHIP_CACHE, etc.) contain
  # home-derived paths that resolve correctly per-user because macOS launchd
  # GUI domains are per-user.  Split into a separate agent to make the
  # scoping intentional and auditable alongside the gui-env-system agent.
  toUserLaunchctlScript =
    let
      os = "macOS";
      relevant = builtins.filter (
        name:
        let
          entry = catalog.${name};
        in
        getScope entry == "all-process"
        && (!entry ? excludeFromLaunchctl || !entry.excludeFromLaunchctl)
        && (entry ? userSpecific && entry.userSpecific)
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

  # ── Introspection for Windows parity tests ───────────────────────
  toJsonManifest = builtins.toJSON (
    builtins.map (
      name:
      let
        entry = catalog.${name};
      in
      {
        inherit name;
        scope = getScope entry;
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
    catalog
    toHomeSessionVariables
    toNixOSSystemEnvironment
    toLaunchctlScript
    toUserLaunchctlScript
    toJsonManifest
    getAllNixVarNames
    resolveValue
    defaultDevTools
    passwordStoreDir
    currentOs
    toLaunchctlPATH
    toNixOSPath
    toWindowsUserPathString
    pathComponents
    ;
}
