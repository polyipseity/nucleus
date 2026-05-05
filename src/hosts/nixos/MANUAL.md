# nixos manual steps

- Review generated hardware config after first install (`nixos-generate-config`) and replace temporary hardware fragments when real device-specific values are available.
- Re-run apply (`nix run ./src#apply`) after any manual hardware migration to verify declarative convergence.
