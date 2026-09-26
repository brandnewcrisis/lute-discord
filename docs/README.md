# lute-discord documentation

New here? Read [Getting started](getting-started.md) first. It goes from an
empty developer portal to a bot answering a slash command.

## Building a bot

- **[Commands](commands.md)**: defining slash commands and context menus,
  options, autocomplete, and publishing them.
- **[Interactions](interactions.md)**: answering a command or a click in
  time, deferring, ephemeral replies, follow-ups, and reading what the user
  sent.
- **[Components](components.md)**: buttons, select menus, collectors, the
  paginator, Components V2 layouts, and modals.
- **[Events](events.md)**: gateway events, the payload type for each one,
  intents, the cache, and shards.

## Reference

- **[REST](rest.md)**: calling the API directly, error handling, rate
  limits, file uploads, webhooks and CDN URLs.
- **[Permissions](permissions.md)**: 64-bit permission flags, channel
  overwrites and role hierarchy.
- **[Utilities](utilities.md)**: the durable store, the scheduler, `.env`
  loading, logging and snowflakes.

## Running it

- **[Deploying](deploying.md)**: secrets, logs, systemd, Docker, sharding,
  and shutting down cleanly.
- **[Troubleshooting](troubleshooting.md)**: what a close code, a missing
  event or an "application did not respond" actually means.

Every module in `src/` opens with a comment explaining the Discord rules it
implements. When these pages and the source disagree, the source is right,
and please open an issue.
