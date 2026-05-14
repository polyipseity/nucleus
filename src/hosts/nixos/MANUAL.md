# nixos manual steps

- After first install, replace temporary hardware fragments with values from `nixos-generate-config`.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive` and `OneDrive` when prompted.
- If you use Gemini CLI, run `gemini` once and complete sign-in.
- Re-run `nix run ./src#apply` after any manual host changes.

## shell aliases (minimal)

- `g` — run `git`.
- `gst` — run `git status`.
- `gpl` — run `git pull`.
- `gp` — run `git push`.
- `ni` — run `bun install`.
- `nr` — run `bun run`.
- `nx` — run `bun x`.
- `v` — open `nvim`.
