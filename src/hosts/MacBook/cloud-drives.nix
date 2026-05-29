# MacBook/cloud-drives.nix — host-scoped cloud replica override.
#
# Keep Google Drive pull-replica disabled on MacBook while preserving the
# shared pull-only sync direction and all other replica defaults.
{
  managedUsername ? null,
  username,
  users,
  ...
}:
let
  currentUsername = if managedUsername != null then managedUsername else username;
  userReplicas = users.${currentUsername}.cloudDrives.replicas or [ ];
in
{
  nucleus.cloudDrives.replicas = map (
    replica: if replica.id == "GoogleDrive" then replica // { enable = false; } else replica
  ) userReplicas;
}
