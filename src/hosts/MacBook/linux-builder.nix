# MacBook/linux-builder.nix — Nix Linux builder VM for Apple Silicon macOS.
#
# Replicates nix.linux-builder.enable = true without the nix.enable assertion
# so it works alongside Determinate Nix (which requires nix.enable = false).
# The builder runs as a launchd-managed lightweight NixOS VM via Apple
# Virtualization.framework and lets the Nix daemon delegate aarch64-linux
# derivations (such as nixos-generators NixOS guest image builds) to it.
# Source: https://daiderd.com/nix-darwin/manual/index.html#opt-nix.linux-builder.enable
{ config, pkgs, ... }:
let
  pkg = pkgs.darwin.linux-builder;
  workDir = "/var/lib/linux-builder";
in
{
  # Register the builder VM so the Nix daemon routes aarch64-linux builds to it.
  # nix-darwin writes /etc/nix/machines from nix.buildMachines regardless of
  # nix.enable, so this works with Determinate Nix (nix.enable = false).
  # base.nix sets builders = @/etc/nix/machines in nix.extraOptions so
  # Determinate Nix actually reads the machines file.
  nix.buildMachines = [
    {
      hostName = "linux-builder";
      sshUser = "builder";
      sshKey = "/etc/nix/builder_ed25519";
      # Deterministic public host key baked into pkgs.darwin.linux-builder so
      # the Nix daemon can verify the builder VM without interactive prompts.
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo=";
      protocol = "ssh-ng";
      # Derived from the builder package so this stays correct if the package
      # is overridden (e.g. to add extra cores or a different guest system).
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

  # SSH config so the Nix daemon and user-level nix commands reach the builder
  # VM on its fixed port without interactive host-key confirmation.
  environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text = ''
    Host linux-builder
      User builder
      Hostname localhost
      HostKeyAlias linux-builder
      Port 31022
      IdentityFile /etc/nix/builder_ed25519
  '';

  # Launchd daemon that keeps the builder VM running.
  # create-builder uses TMPDIR to share TLS certificates with the VM; the
  # default /tmp is auto-cleaned by macOS after 3 days of inactivity, silently
  # breaking the builder after a long sleep.  Use a dedicated /run path that
  # we own and clean ourselves instead.
  launchd.daemons.linux-builder = {
    environment = { inherit (config.environment.variables) NIX_SSL_CERT_FILE; };
    script = ''
      export TMPDIR=/run/org.nixos.linux-builder USE_TMPDIR=1
      rm -rf $TMPDIR
      mkdir -p $TMPDIR
      trap "rm -rf $TMPDIR" EXIT
      ${pkg}/bin/create-builder
    '';
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      WorkingDirectory = workDir;
    };
  };

  # Ensure the builder's working directory exists before the daemon starts.
  # Also migrates from the old path used by nix-darwin before v5.
  system.activationScripts.preActivation.text = ''
    if [ -e /var/lib/darwin-builder ] && [ ! -e ${workDir} ]; then
      mv /var/lib/darwin-builder ${workDir}
    fi
    mkdir -p ${workDir}
  '';
}
