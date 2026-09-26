# src/modules/posix/sops.nix — Machine age-key derivation for POSIX hosts.
#
# Derives the age secret identity from /etc/ssh/ssh_host_ed25519_key and writes
# it to /Library/Application Support/nucleus/sops/age/machine.txt (macOS) or
# /var/lib/nucleus/sops/age/machine.txt (NixOS) so the Home Manager sops-nix
# instance can decrypt SOPS secrets without root.
#
# Why a dedicated derived file rather than sshKeyPaths in Home Manager:
#   /etc/ssh/ssh_host_ed25519_key is owned root:wheel (macOS) or root:root
#   (NixOS) with mode 0600. The Home Manager sops-nix instance runs as the
#   regular user; ssh-to-age must read the private key to derive the age
#   identity and fails with "permission denied" in that context. System
#   activation runs as root and CAN read the host key, so we derive the age
#   identity there and write it to a path the user can read:
#   /var/lib/nucleus/sops/age/machine.txt is owned root:nucleus-sops (mode
#   0640) on NixOS, or by the primary user (mode 0600) on nix-darwin. Home
#   Manager references it through sops.age.keyFile in secrets.nix.
#
# Idempotency:
#   ssh-to-age is deterministic for a given SSH key; repeated runs always
#   produce identical output. We always overwrite to keep the file current if
#   the host key is ever rotated.
{
  lib,
  pkgs,
  username,
  users ? { },
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  activationBundle = pkgs.callPackage ../lib/script-tree.nix { };
  sopsGroup = "nucleus-sops";
  # darwin: the key belongs to the primary user, so HM reads it directly.
  # NixOS: a root-owned key needs a group so every managed user can read it.
  machineAgeOwnerSpec = if isDarwin then "user:${username}" else "group:${sopsGroup}";
  deriveHostAgeKey = ''
    "${activationBundle}/src/scripts/secrets/derive-host-age-key.sh" \
      "${pkgs.ssh-to-age}/bin/ssh-to-age" \
      "${machineAgeOwnerSpec}"
  '';
in
{
  # WHY: derive-host-age-key.sh chowns the key to group:nucleus-sops on NixOS,
  # so the group must exist or the derivation hard-fails.
  users.groups.${sopsGroup} = lib.mkIf (!isDarwin) { };

  # WHY: the group grants read access to a key that decrypts every SOPS secret.
  # Narrowing it to only the users that decrypt secrets is a real security
  # improvement, but the user registry does not record which users decrypt, so
  # the broad grant stands until that fact is available.
  users.users = lib.mkIf (!isDarwin) (
    lib.genAttrs (builtins.attrNames users) (_name: {
      extraGroups = lib.mkAfter [ sopsGroup ];
    })
  );

  system.activationScripts =
    if isDarwin then
      {
        # nix-darwin only honours the hardcoded postActivation fragment name.
        postActivation.text = lib.mkBefore deriveHostAgeKey;
      }
    else
      {
        nixos-derive-host-age-key.text = deriveHostAgeKey;
      };
}
