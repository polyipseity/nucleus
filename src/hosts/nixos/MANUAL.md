# nixos manual steps

- After first install, replace temporary hardware fragments with values from `nixos-generate-config`.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive` and `OneDrive` when prompted.
- If you use Gemini CLI, run `gemini` once and complete sign-in.
- Re-run `nix run ./src#apply` after any manual host changes.
