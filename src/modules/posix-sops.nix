# modules/posix-sops.nix — Shared SOPS decryption key sources for POSIX hosts.
{ pkgs, username, ... }:
{
  # ---------------------------------------------------------------------------
  # deriveHostAgeKey
  # Derives the age secret identity from the machine's SSH host key and writes
  # it to /etc/sops/age/machine.txt so the Home Manager sops-nix instance can
  # decrypt SOPS secrets without requiring root privileges.
  #
  # Why a dedicated derived file rather than sshKeyPaths in Home Manager:
  #   /etc/ssh/ssh_host_ed25519_key is owned root:wheel (macOS) or root:root
  #   (NixOS) with mode 0600.  The Home Manager sops-nix instance runs as the
  #   regular user; ssh-to-age must read the private key to derive the age
  #   identity and fails with "permission denied" in that context.  System
  #   activation runs as root and CAN read the host key, so we derive the age
  #   identity there and write it to a user-readable path:
  #   /etc/sops/age/machine.txt is owned by username (mode 0600) and is
  #   referenced via sops.age.keyFile in secrets.nix.
  #
  #   The system-level sops-nix instance (this module) keeps sshKeyPaths
  #   because system activation already runs as root.
  #
  # Idempotency:
  #   ssh-to-age is deterministic for a given SSH key; repeated runs always
  #   produce identical output.  We always overwrite to keep the file current
  #   if the host key is ever rotated.
  # ---------------------------------------------------------------------------
  system.activationScripts.deriveHostAgeKey.text = ''
    age_dir="/etc/sops/age"
    age_key_file="$age_dir/machine.txt"
    host_ssh_key="/etc/ssh/ssh_host_ed25519_key"

    if [ ! -f "$host_ssh_key" ]; then
      echo "nucleus: /etc/ssh/ssh_host_ed25519_key absent; skipping age key derivation." >&2
      echo "nucleus:   This machine cannot decrypt SOPS secrets as a device age recipient" >&2
      echo "nucleus:   until the host key is present and registered in .sops.yaml." >&2
    else
      mkdir -p "$age_dir"
      # Use the || exit_code=$? pattern to prevent set -e (active in
      # nix-darwin/NixOS activation scripts) from exiting the script when
      # ssh-to-age fails.  Without this guard a non-zero ssh-to-age exit
      # silently aborts activation before the check below can emit a diagnostic.
      derived_age_key_exit=0
      derived_age_key="$(${pkgs.ssh-to-age}/bin/ssh-to-age < "$host_ssh_key")" || derived_age_key_exit=$?
      if [ "$derived_age_key_exit" -ne 0 ] || [ -z "$derived_age_key" ]; then
        echo "nucleus: ssh-to-age failed (exit $derived_age_key_exit) reading $host_ssh_key; $age_key_file not written." >&2
      else
        printf '%s\n' "$derived_age_key" > "$age_key_file"
        chown "${username}" "$age_key_file"
        chmod 0600 "$age_key_file"
      fi
    fi
  '';

  sops = {
    age = {
      # System activation runs as root and can read /etc/ssh/ssh_host_ed25519_key
      # directly; keep sshKeyPaths for the system-level sops-nix instance.
      # The Home Manager sops-nix instance (secrets.nix) references
      # /etc/sops/age/machine.txt (derived by deriveHostAgeKey above) via
      # sops.age.keyFile to avoid the user-permission issue at HM activation time.
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };

    # GnuPG fallback path differs by platform home directory convention.
    gnupg.home =
      if pkgs.stdenv.isDarwin then
        "/Users/${username}/.gnupg"
      else
        "/home/${username}/.gnupg";
  };
}
