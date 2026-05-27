# MacBook/linux-builder.nix — Nix Linux builder VM for Apple Silicon macOS.
#
# Replicates nix.linux-builder.enable = true without the nix.enable assertion
# so it works alongside Determinate Nix (which requires nix.enable = false).
# The builder runs as a launchd-managed lightweight NixOS VM via Apple
# Virtualization.framework and lets the Nix daemon delegate aarch64-linux
# derivations (such as nixos-generators NixOS guest image builds) to it.
# Source: https://daiderd.com/nix-darwin/manual/index.html#opt-nix.linux-builder.enable
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  pkg = pkgs.darwin.linux-builder;
  workDir = "/var/lib/linux-builder";
  # Nix 2.34.x currently fails to start ssh-ng master sessions against the
  # nix-darwin linux-builder on this host, while the legacy ssh:// builder path
  # works for the same derivations. Keep the builder registration on ssh:// so
  # distributed builds remain functional until upstream ssh-ng/master startup is
  # fixed.
  # For the legacy ssh:// path, rely on the managed Host/HostKeyAlias/
  # UserKnownHostsFile config below instead of Nix's inline host-key field; the
  # inline field bypasses that alias handling and breaks host verification here.
  builderMachine = "ssh://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 1 benchmark,big-parallel,kvm - -";
  userSshDir = "/Users/${username}/.ssh";
  userBuilderKeyPath = "${userSshDir}/linux-builder_ed25519";
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
      protocol = "ssh";
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

  # Determinate Nix keeps the daemon config, but the builder machine file is
  # not materialized automatically here, so we write it explicitly.
  environment.etc."nix/machines".text = "${builderMachine}\n";

  # Root (Nix daemon) must verify the builder host key without an interactive
  # prompt. Keep a deterministic pinned entry in /etc/nix so ssh-ng can use it
  # even when /var/root/.ssh/known_hosts does not exist.
  environment.etc."nix/linux-builder-known_hosts".text = ''
    linux-builder ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJBWcxb/Blaqt1auOtE+F8QUWrUotiC5qBJ+UuEWdVCb
  '';

  # SSH config so the Nix daemon and user-level nix commands reach the builder
  # VM on its fixed port without interactive host-key confirmation.
  # Upstream installs /etc/nix/builder_ed25519 as root:nixbld 0600, which is
  # correct for the daemon but unreadable to user-space ssh-ng clients.
  # Route root to the daemon-owned key and the primary user to a dedicated 0600
  # mirror so nix store / nixos-generators probes never fall back to password.
  environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text = ''
    Host linux-builder
      User builder
      Hostname localhost
      HostKeyAlias linux-builder
      Port 31022
      IdentitiesOnly yes
      UserKnownHostsFile /etc/nix/linux-builder-known_hosts
      StrictHostKeyChecking yes

    Match originalhost linux-builder localuser root
      IdentityFile /etc/nix/builder_ed25519

    Match originalhost linux-builder localuser ${username}
      IdentityFile ${userBuilderKeyPath}
  '';

  # Mirror the builder key into the primary user's SSH directory without
  # weakening the daemon key permissions. This macOS-only copy is the smallest
  # parity-safe exception because Linux and Windows do not use nix-darwin's
  # root-owned linux-builder helper at all.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    if [ -f /etc/nix/builder_ed25519 ]; then
      install -d -m 700 -o ${username} ${userSshDir}
      install -m 600 -o ${username} /etc/nix/builder_ed25519 ${userBuilderKeyPath}
    fi
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
    mkdir -p /var/root/.ssh
    chmod 700 /var/root/.ssh
  '';
}
