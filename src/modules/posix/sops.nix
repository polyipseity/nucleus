# src/modules/posix/sops.nix — Machine age-key derivation for POSIX hosts.
#
# Derives the age identity from /etc/ssh/ssh_host_ed25519_key under the SYSTEM
# root, where the Home Manager sops-nix instance can read it without root.
#
# Not via Home Manager sshKeyPaths: the host key is root-owned mode 0600 and
# ssh-to-age fails with "permission denied" as a regular user. System activation
# runs as root, reads the host key, and writes a file the user can read (NixOS
# root:nucleus-sops 0640, nix-darwin primary user 0600). secrets.nix references
# it through sops.age.keyFile.
#
# Always overwrites: ssh-to-age is deterministic, so a host key rotation takes
# effect on the next run.
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
  # The grant cannot be narrower: the user registry records no per-user decrypt
  # capability, so recording that has to come first.
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
