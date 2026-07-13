# MacBook/services.nix — General macOS service configurations.
#
# Coordinates Quick Actions (services/quick-actions.nix) and App Services
# (services/app-services.nix) file imports. App Services sub-module handles
# its own daemon cache flush (via daemon-refresh.nix) at the end of its
# activation script so Quick Actions changes (DAG-parallel) are also covered.
#
# For Quick Actions (Automator .workflow bundles appearing in right-click →
# Quick Actions): see services/quick-actions.nix
#
# For App Services (.app bundles appearing in menu bar → Services):
# see services/app-services.nix
{ ... }: {
  imports = [
    ./services/quick-actions.nix
    ./services/app-services.nix
  ];
}
