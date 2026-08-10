# src/vms/guests/NixOS/guest.nix — Per-VM NixOS guest configuration delta.
#
# Adds the per-VM identity (hostname, login user, password, SSH key) on top of
# the shared type-scoped src/vms/NixOS/base-guest.nix.  This file is consumed
# at setup time (offline disk injection, see vm_inject_guest), NOT by the type
# build: the shared system image stays identity-free so one image serves every
# VM of this type.  The host exports NUCLEUS_VM_GUEST_* environment variables
# from per-user SOPS secrets before evaluating this configuration.
{
  lib,
  ...
}:
let
  guestUsername = builtins.getEnv "NUCLEUS_VM_GUEST_USERNAME";
  guestPassword = builtins.getEnv "NUCLEUS_VM_GUEST_PASSWORD";
in
{
  imports = [
    # WHY: relative to src/vms/guests/NixOS/, the type base is two levels up.
    ../../NixOS/base-guest.nix
  ];

  # Titlecase hostname preserves consistent local discovery and machine
  # identity semantics.  WHY mkForce: hosts/NixOS/networking.nix (imported via
  # the type base) sets networking.hostName as a plain definition, and the
  # mergeEqualOption merge would reject a different per-VM hostname at the same
  # priority; force the per-VM value so identity always wins over the type
  # default.
  networking.hostName = lib.mkForce (builtins.getEnv "NUCLEUS_VM_GUEST_HOSTNAME");

  # WHY: override the generic placeholders threaded by base-guest.nix through
  # _module.args (mkDefault) with this VM's real identity from the
  # NUCLEUS_VM_GUEST_* environment variables so posix-base.nix's gitconfig and
  # the shared user modules key off the actual guest user.
  _module.args = {
    hostName = builtins.getEnv "NUCLEUS_VM_GUEST_HOSTNAME";
    username = guestUsername;
  };

  users.users."${guestUsername}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = guestPassword;
    openssh.authorizedKeys.keys = [ (builtins.getEnv "NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY") ];
  };
}
