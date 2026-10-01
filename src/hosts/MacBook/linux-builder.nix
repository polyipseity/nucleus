# MacBook/linux-builder.nix - Nix Linux builder VM for Apple Silicon macOS.
#
# WHY not nix.linux-builder.enable: that option asserts nix.enable = true, and
# Determinate Nix requires nix.enable = false. This replicates the builder
# without the assertion, so aarch64-linux derivations delegate to a
# launchd-managed lightweight NixOS VM over Apple Virtualization.framework.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  pkg = pkgs.darwin.linux-builder.override {
    modules = [
      (
        { pkgs, ... }:
        {
          environment.systemPackages = [ pkgs.jq ];
          nix.settings = {
            experimental-features = [
              "flakes"
              "nix-command"
            ];
            auto-optimise-store = true;
            extra-substituters = [ "https://nix-community.cachix.org" ];
            extra-trusted-public-keys = [
              "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
            ];
          };
          nix.gc = {
            automatic = true;
            dates = "12:00";
            options = "--delete-older-than 7d";
          };
        }
      )
    ];
  };
  workDir = "/Library/Application Support/nucleus/linux-builder";
  # WHY ssh:// and not ssh-ng: Nix 2.34.x master sessions fail against the darwin
  # linux-builder, and the host-key check comes from the managed SSH config
  # instead of Nix's inline field.
  builderMachine = "ssh://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 1 benchmark,big-parallel,kvm - -";
  userSshDir = "/Users/${username}/.ssh";
  userBuilderKeyPath = "${userSshDir}/linux-builder_ed25519";

  envVars = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "MacBook";
  };
  resolveValue = name: envVars.resolveValue name "MacBook";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    # WHY: launchd sets no HOME for a root daemon and lib.sh needs it for
    # derive_nucleus_user_root(). Root's home on macOS is always /var/root.
    HOME = "/var/root";
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };

  # WHY a dedicated TMPDIR: macOS auto-cleans the default /tmp after 3 days of
  # inactivity, which silently breaks the builder after a long sleep, and
  # create-builder uses TMPDIR to share TLS certificates with the VM.
  # WHY no runtimeInputs: create-builder is resolved from /nix/store at runtime
  # to avoid the cycle daemon -> create-builder -> nixos-vm -> linux-builder.
  linuxBuilderDaemon = pkgs.writeNucleusShellApplication {
    name = "linux-builder-daemon";
    scriptName = "src/hosts/MacBook/scripts/macos-daemonize-linux-builder";
  };
in
{
  # WHY this works with Determinate Nix: nix-darwin writes /etc/nix/machines
  # from nix.buildMachines regardless of nix.enable, and base.nix sets
  # builders = @/etc/nix/machines so Determinate reads that file.
  nix.buildMachines = [
    {
      hostName = "linux-builder";
      sshUser = "builder";
      sshKey = "/etc/nix/builder_ed25519";
      protocol = "ssh";
      systems = [ pkg.nixosConfig.nixpkgs.hostPlatform.system ];
      maxJobs = pkg.nixosConfig.virtualisation.cores;
      speedFactor = 1;
      supportedFeatures = [
        "benchmark"
        "big-parallel"
        "kvm"
      ];
    }
  ];

  # Determinate Nix does not materialize the builder machine file, so write it.
  environment.etc."nix/machines".text = "${builderMachine}\n";

  # check-suppress:config-method: method 2 (read-only) -- Derived from SOPS secrets and machine identity -- not user-editable content.
  environment.etc."nix/linux-builder-known_hosts".text = # check-suppress:config-method: method 2 (read-only)
    builtins.readFile ../../modules/configs/ssh/linux-builder-known_hosts;

  # WHY: upstream installs /etc/nix/builder_ed25519 as root:nixbld 0600, which
  # the daemon reads but user-space ssh-ng clients cannot. Root is routed to the
  # daemon-owned key and the primary user to a 0600 mirror, so store and
  # nixos-generators probes never fall back to a password.
  # check-suppress:config-method: method 2 (read-only) -- Builder VM wiring -- modifying port/address requires coordinated changes across multiple files, so changes go through Nix eval.
  environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text =
    builtins.replaceStrings
      [ "__USERNAME__" "__USER_BUILDER_KEY_PATH__" ]
      [ username userBuilderKeyPath ]
      (builtins.readFile ../../modules/configs/ssh/ssh_config.d/100-linux-builder.conf);

  # Mirror the builder key into the primary user's SSH directory without
  # weakening the daemon key permissions.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    if [ -f /etc/nix/builder_ed25519 ]; then
      install -d -m 700 -o ${username} ${userSshDir}
      install -m 600 -o ${username} /etc/nix/builder_ed25519 ${userBuilderKeyPath}
    fi
  '';

  # Disabled by default to save ~500 MiB RAM. Start and stop it with
  # nucleus-svc; nucleus-apply and nucleus-vm do it as needed.
  launchd.daemons.linux-builder = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed.
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      # Do not revisit the descriptive service name until nix-darwin issue
      # 1219 is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${linuxBuilderDaemon}/bin/nucleus-linux-builder-daemon '${workDir}'"
      ];
      KeepAlive = false;
      RunAtLoad = false;
      WorkingDirectory = workDir;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/linux-builder/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/linux-builder/stderr.log";
      EnvironmentVariables = daemonEnv;
    };
  };

  # workDir contains a space ("Application Support"), so quote it or the shell
  # tries to mkdir "Support" at the read-only root.
  system.activationScripts.preActivation.text = ''
    mkdir -p "${workDir}"
    mkdir -p /var/root/.ssh
    chmod 700 /var/root/.ssh
  '';
}
