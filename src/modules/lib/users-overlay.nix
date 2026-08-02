# src/modules/lib/users-overlay.nix — Generic per-user overlay file selection.
#
# Resolves src/users/<username>/<config>/<Host>.<ext> with
# src/users/default/<config>/<Host>.<ext> fallback (AGENTS.md convention).
# The per-user file wins when it exists; otherwise the default applies.
# Callers pass their config name explicitly, so future configs (direnv, etc.)
# reuse this selector instead of duplicating path logic.
{
  configName,
  ext,
  hostName,
  effectiveUsername,
  repoRoot,
}:
let
  perUser = "${repoRoot}/src/users/${effectiveUsername}/${configName}/${hostName}.${ext}";
  default = "${repoRoot}/src/users/default/${configName}/${hostName}.${ext}";
in
if builtins.pathExists perUser then perUser else default
