# src/modules/lib/activation-bundle.nix
# Single derivation that assembles all activation scripts into a self-contained
# $out/bin + $out/lib tree. Scripts source library dependencies via SCRIPT_DIR-
# relative paths, eliminating builtins.readFile concatenation in activation
# blocks and cross-file dependency tracking at Nix eval time.
#
# Every script under $out/bin/ is a standalone executable that:
#   1. Sets SCRIPT_DIR from $0
#   2. Sources needed libs via "$SCRIPT_DIR/../lib/<name>.sh"
#   3. Parses CLI args for per-user values
#   4. Executes the activation logic
#
# All activation blocks invoke these scripts as subprocesses.
# No inline ${builtins.readFile} in activation bodies.
{ pkgs }:

let
  # Path literals (must be relative to this file's location) — Nix adds them
  # to the derivation store path context automatically when interpolated.
  p = {
    lib = {
      "symlink-hardening-lib.sh" = ../../../src/scripts/lib/symlink-hardening-lib.sh;
      "symlink-convergence-lib.sh" = ../../../src/scripts/lib/symlink-convergence-lib.sh;
      "dev-repos-provision-lib.sh" = ../../../src/scripts/lib/dev-repos-provision-lib.sh;
      "macos-fda-warning-lib.sh" = ../../../src/scripts/lib/macos-fda-warning-lib.sh;
      "macos-launch-services-lib.sh" = ../../../src/scripts/lib/macos-launch-services-lib.sh;
      "macos-icloud-exclusions-lib.sh" = ../../../src/scripts/lib/macos-icloud-exclusions-lib.sh;
      "macos-finder-sidebar-lib.sh" = ../../../src/scripts/lib/macos-finder-sidebar-lib.sh;
      "repo-root-lib.sh" = ../../../src/scripts/lib/repo-root-lib.sh;
      "require-command-lib.sh" = ../../../src/scripts/lib/require-command-lib.sh;
      "argparse-lib.sh" = ../../../src/scripts/lib/argparse-lib.sh;
    };
    bin = {
      symlink-agent-config = ../../../src/scripts/agents/symlink-agent-config.sh;
      install-agent-skills = ../../../src/scripts/agents/install-agent-skills.sh;
      install-bun-packages = ../../../src/scripts/packages/install-bun-packages.sh;
      install-uv-tools = ../../../src/scripts/packages/install-uv-tools.sh;
      init-rustup = ../../../src/scripts/packages/init-rustup.sh;
      install-cargo-binstall-packages = ../../../src/scripts/packages/install-cargo-binstall-packages.sh;
      sync-clawhub-skills = ../../../src/scripts/agents/sync-clawhub-skills.sh;
      provision-symlinks = ../../../src/scripts/configs/provision-symlinks.sh;
      finalize-symlinks = ../../../src/scripts/configs/finalize-symlinks.sh;
      ensure-symlink-targets = ../../../src/scripts/configs/ensure-symlink-targets.sh;
      symlink-vscode-config = ../../../src/scripts/editors/symlink-vscode-config.sh;
      bridge-vscode-extensions = ../../../src/scripts/editors/bridge-vscode-extensions.sh;
      cloud-drives-setup = ../../../src/scripts/services/cloud-drives-setup.sh;
      raycast-aliases = ../../../src/scripts/hosts/MacBook/macos-install-raycast-aliases.sh;
      provision-dev-repos = ../../../src/scripts/configs/provision-dev-repos.sh;
      configure-git-identity = ../../../src/scripts/secrets/configure-git-identity.sh;
      configure-gpg-agent = ../../../src/scripts/secrets/configure-gpg-agent.sh;
      import-gpg-key = ../../../src/scripts/secrets/import-gpg-key.sh;
      install-pwsh-module = ../../../src/scripts/packages/install-pwsh-module.sh;
      adopt-ssh-key = ../../../src/scripts/secrets/adopt-ssh-key.sh;
      assemble-git-ignore = ../../../src/scripts/configs/assemble-git-ignore.sh;
      verify-secret-decryption = ../../../src/scripts/secrets/verify-secret-decryption.sh;
      wait-for-sops-secrets = ../../../src/scripts/secrets/wait-for-sops-secrets.sh;
      configure-linearmouse = ../../../src/scripts/hosts/MacBook/macos-configure-linearmouse.sh;
      preflight-privacy = ../../../src/scripts/hosts/MacBook/macos-configure-preflight-privacy.sh;
      safari-defaults = ../../../src/scripts/hosts/MacBook/macos-configure-safari-defaults.sh;
      universal-access-defaults = ../../../src/scripts/hosts/MacBook/macos-configure-universal-access.sh;
      headless-display = ../../../src/scripts/hosts/MacBook/macos-configure-headless-display.sh;
      derive-host-age-key = ../../../src/scripts/secrets/derive-host-age-key.sh;
      display-resolutions = ../../../src/scripts/hosts/MacBook/macos-display-resolutions.sh;
      nightlight = ../../../src/scripts/hosts/MacBook/macos-install-nightlight.sh;
      ensure-launchagents = ../../../src/scripts/hosts/MacBook/macos-ensure-launchagents.sh;
      gui-env-path = ../../../src/scripts/hosts/MacBook/macos-set-gui-env-path.sh;
      install-zsh-completions = ../../../src/scripts/shell/install-zsh-completions.sh;
      verify-archiving-stack = ../../../src/scripts/packages/verify-archiving-stack.sh;
      merge-qtpass-ini = ../../../src/scripts/configs/merge-qtpass-ini.sh;
      merge-picard-ini = ../../../src/scripts/configs/merge-picard-ini.sh;
      merge-obsidian-json = ../../../src/scripts/configs/merge-obsidian-json.sh;
      provision-wallpaper = ../../../src/scripts/provision-wallpaper.sh;
      trust-vscode-workspace = ../../../src/scripts/editors/trust-vscode-workspace.sh;
      update-nix-index = ../../../src/scripts/packages/update-nix-index.sh;

      # Thin wrappers consolidated from inline activation blocks
      managed-symlink = ../../../src/scripts/configs/managed-symlink.sh;
      manage-out-of-store-symlinks = ../../../src/scripts/configs/manage-out-of-store-symlinks.sh;
      configure-launch-services = ../../../src/scripts/hosts/MacBook/macos-configure-launch-services.sh;
      configure-icloud-exclusions = ../../../src/scripts/hosts/MacBook/macos-configure-icloud-exclusions.sh;
      configure-finder-sidebar = ../../../src/scripts/hosts/MacBook/macos-configure-finder-sidebar.sh;
      relaunch-desktop-services = ../../../src/scripts/hosts/MacBook/macos-relaunch-desktop-services.sh;
      reload-dock-preference-state = ../../../src/scripts/hosts/MacBook/macos-reload-dock-preference-state.sh;
      configure-input-config = ../../../src/scripts/hosts/MacBook/macos-configure-input-config.sh;
      macos-deploy-app-bundles = ../../../src/scripts/hosts/MacBook/macos-deploy-app-bundles.sh;
      macos-deploy-automator-workflows = ../../../src/scripts/hosts/MacBook/macos-deploy-automator-workflows.sh;
      reload-user-preference-state = ../../../src/scripts/hosts/MacBook/macos-reload-user-preference-state.sh;

      # NixOS system activation scripts
      launch-nvim = ../../../src/scripts/editors/launch-nvim.sh;
      log-dirs-init = ../../../src/scripts/services/log-dirs-init.sh;
    };
  };

  # Build a Nix string that copies each file in a mapping to $out/<subdir>/<key>.
  # Each value in the mapping must be a Nix path literal so ${path} creates a store dep.
  copyAll =
    subdir: mapping:
    builtins.concatStringsSep "\n" (
      builtins.attrValues (
        builtins.mapAttrs (name: path: ''
          cp "${path}" "$out/${subdir}/${name}"
          chmod +x "$out/${subdir}/${name}"
        '') mapping
      )
    );
in
pkgs.runCommand "nucleus-activation-bundle"
  {
    preferLocalBuild = true;
    buildInputs = [ pkgs.bash ];
  }
  ''
    set -eu
    mkdir -p "$out/bin" "$out/lib"

    ${copyAll "lib" p.lib}
    ${copyAll "bin" p.bin}
  ''
