# Hermes channel credentials

The `gateway` profile enables Telegram, Discord, and ntfy. It carries no
credentials: activation materializes the SOPS-backed `.env` beside the profile,
and Hermes reads the values from there. The names below come from the pinned
Hermes `v2026.9.24` platform manifests and adapters.

| Channel | Environment names | Notes |
| --- | --- | --- |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS` | Unknown direct messages get a pairing code; the repo allowlist is empty. |
| Discord | `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_USERS`, `DISCORD_ALLOWED_ROLES`, `DISCORD_ALLOWED_CHANNELS` | Slash commands fail closed until an allowlist names a user, role, or channel. |
| ntfy | `NTFY_TOPIC`, `NTFY_TOKEN`, optional `NTFY_SERVER_URL` | Use a private topic and its read token. ntfy has no native user identity, so the topic and token are the trust boundary. |

Discord admin IDs for exec approvals go in
`platforms.discord.extra.allow_admin_from` in a user overlay; the repo leaves
that list empty and `require_admin_for_exec_approval` on, so approval buttons
stay unavailable until an admin is named. Fixed allowlists in the gateway
profile are empty on purpose. Fill them in a user overlay after the owner has
confirmed the paired identity. Do not set any `allow_all_users` flag.
