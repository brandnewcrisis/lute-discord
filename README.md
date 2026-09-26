# lute-discord

[![ci](https://github.com/brandnewcrisis/lute-discord/actions/workflows/ci.yml/badge.svg)](https://github.com/brandnewcrisis/lute-discord/actions/workflows/ci.yml)

A Discord bot library for [Lute](https://github.com/luau-lang/lute), the
standalone Luau runtime.

Lute ships an HTTP client and a WebSocket client. Those are the only two
pieces of the network a Discord bot needs, and this library builds the rest
on top of them in strict-mode Luau:

- the gateway lifecycle and sharding
- a bucket-aware rate limiter
- the interaction protocol
- builders that fail at the call site instead of at the API
- permission arithmetic that Discord doesn't expose as an endpoint

```luau
local Discord = require("@discord")

local env = Discord.Env.load()
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
})

client:command("ping", function(ix: Discord.Interaction)
	ix:reply(`pong ({math.floor(client:latency() * 1000)} ms)`)
end)

client:deploy({ Discord.Commands.slash("ping", "Check the bot is alive") }, env:get("DISCORD_GUILD_ID"))
client:run()
```

## What it covers

| Area | |
| --- | --- |
| **Gateway** | Jittered heartbeats and zombie detection. RESUME against the right URL, and resume after its own teardown. Reconnect with backoff, and a clean stop on fatal close codes. Automatic sharding with `max_concurrency` identify buckets, and a send budget. Member chunking (`fetchMembers`) and voice state updates. |
| **REST** | About 200 routes across 14 namespaces: messages, channels, threads, forum posts, pins, guilds, members, roles, bans, emoji, stickers, soundboard, stage instances, scheduled events, auto-moderation, templates, onboarding, webhooks, invites, polls, commands, application emoji, entitlements, SKUs, subscriptions. Also CDN URL helpers. |
| **Rate limits** | Buckets learned from response headers and keyed per major parameter, one request in flight per bucket, the global limit handled up front, and 429 and 5xx retried with jittered backoff. |
| **Interactions** | Slash commands, subcommands and groups, context menus, autocomplete, buttons, five select kinds, and modals. `reply` works in every state (fresh, deferred or already answered), so a handler never has to track which one it's in. |
| **Components V2** | Containers, sections, text displays, thumbnails, media galleries, files and separators. The flag and the content restrictions are enforced for you. |
| **Modals** | Labels, text inputs, selects, file uploads, radio groups, checkbox groups and checkboxes, with typed readers for each. |
| **Builders** | Embeds, components, modals and commands. Each checks Discord's limits where the mistake is made, and names the rule it broke. |
| **Permissions** | 64-bit flag arithmetic, full channel-overwrite resolution, role hierarchy, and timeouts. |
| **Extras** | An event cache, collectors, a paginator, multipart uploads and a webhook client that needs no bot. Also a crash-durable JSON store, a cancellable scheduler, `.env` loading, snowflake decoding and levelled logging. |

**Not covered: voice audio.** It needs a UDP socket and an Opus encoder, and
Lute has neither. A bot can still join and leave voice channels.

## Install

Lute has no package registry, so the library is vendored: a copy of this
repository plus an alias.

```bash
git submodule add https://github.com/brandnewcrisis/lute-discord.git vendor/lute-discord
```

Then point a `.luaurc` alias at `src/`. The alias must be called `discord`,
because the library's modules require each other as `@discord/...`:

```json
{
  "languageMode": "strict",
  "aliases": { "discord": "./vendor/lute-discord/src" }
}
```

The library targets **Lute 1.0.0**. `rokit install` in this repository
fetches that version.

## Documentation

Start with **[Getting started](docs/getting-started.md)**, which covers
creating the application, the token, the invite link and a first bot.

| Guide | |
| --- | --- |
| [Commands](docs/commands.md) | Slash commands, options, subcommands, context menus, autocomplete, deploying |
| [Interactions](docs/interactions.md) | Replying, deferring, ephemeral messages, follow-ups, reading options |
| [Components](docs/components.md) | Buttons, selects, collectors, the paginator, Components V2, modals |
| [Events](docs/events.md) | Gateway events and their payload types, intents, the cache, shards |
| [REST](docs/rest.md) | Calling the API directly, errors, rate limits, files, webhooks, CDN |
| [Permissions](docs/permissions.md) | Flags, channel overwrites, role hierarchy |
| [Utilities](docs/utilities.md) | Storage, the scheduler, `.env`, logging, snowflakes |
| [Deploying](docs/deploying.md) | systemd, Docker, secrets, logs, sharding, shutting down cleanly |
| [Troubleshooting](docs/troubleshooting.md) | Common failures and what causes them |

The source is also written to be read. Every module opens with a comment
explaining the Discord rules it implements and why.

## Examples

- **[`examples/minimal`](examples/minimal/main.luau)**: one command, one
  button, one event, in under fifty lines.
- **[`examples/kitchensink`](examples/kitchensink)**: a working bot with 37
  commands across six modules, using nearly every part of the library.

To run either one, copy `.env.example` to `.env`, paste a bot token, set
`DISCORD_GUILD_ID` to a test server, then:

```bash
lute run examples/minimal/main.luau
```

```bash
lute run examples/kitchensink/main.luau
```

| Module | Commands |
| --- | --- |
| `core` | `/ping` `/help` `/stats` `/shutdown` |
| `info` | `/userinfo` `/serverinfo` `/avatar` `/roleinfo` `/snowflake` `/perms`, plus **Who is this** and **Quote this** context menus |
| `fun` | `/roll` `/choose` `/8ball` `/poll` |
| `ui` | `/buttons` `/menu` `/feedback` `/card` `/paginate` `/confirm` `/timer` |
| `moderation` | `/kick` `/ban` `/unban` `/timeout` `/purge` `/slowmode` `/nick` |
| `utility` | `/weather` `/tag` (4 subcommands) `/remind` `/say` `/upload` `/colour` `/reactionrole` |

Each command demonstrates one specific thing:

| Command | Shows |
| --- | --- |
| `/poll` | State encoded in `custom_id` |
| `/confirm` | A collector awaited as straight-line code |
| `/timer` | Deferring past the three-second window |
| `/feedback` | A modal with labels, a radio group, a file upload and a checkbox |
| `/card` | A Components V2 layout with no embed |
| `/say` | Creating, using and deleting a webhook |
| `/perms` | Channel permissions computed locally, which Discord won't tell you |

## Development

```bash
rokit install
lute run tools/check.luau              # typecheck every file
lute lint src examples tests tools
lute run tests/run.luau                # 24 suites, about 1,600 checks, about 15 seconds
```

The tests run offline. The network layer is driven through a scripted REST
transport and a fake gateway socket (`tests/fakes.luau`), which covers:

- rate-limit buckets, 429 and 5xx handling, and multipart bodies
- the heartbeat, resume and reconnect state machine
- fatal close codes and identify pacing
- event routing, command and component dispatch
- cache maintenance

`tools/smoke.luau` runs against a real server: uploads, reactions, webhooks,
a Components V2 message and a 20-message burst through the rate limiter. It
deletes everything it creates.

```bash
lute run tools/smoke.luau <channelId>
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the house rules.

## Lute notes

Things this library works around, collected in case they bite you elsewhere.
All were verified against Lute 1.0.0.

- **An uncaught error that is a table prints nothing**, not even
  `table: 0x...`, only a stack trace. REST failures throw an `ApiError`
  table, so scripts should wrap their body in `Discord.main(fn)`, which
  prints the message. `Client.deploy`, `login` and `run` raise plain text
  for the same reason.
- **Timers can't be cancelled.** A pending `task.delay(3600, ...)` keeps the
  process alive for the hour, even after closing its thread. Long waits in
  this library are sliced (`Util.sleepWhile`), so `stop()` actually lets the
  process exit.
- **`@std/json` marks decoded objects with a userdata sentinel key**, and
  decodes `null` to `json.null`, not `nil`. `src/json.luau` strips both at
  the decode boundary. An empty table serialises to `[]`, so use
  `Json.object()` where Discord wants `{}`.
- **`fs.open(path, "a")` errors if the file doesn't exist**, despite its
  docstring. There is no `fs.rename`, so `src/storage.luau` builds its
  crash safety on `fs.copy`, which overwrites.
- **stdout is block-buffered when it isn't a TTY**, so a bot under `nohup`
  logs nothing. Set `LOG_FILE`.
- **`math.random` is unseeded and identical across processes.** `Util`
  seeds it from `crypto.secretbox.keygen()` at load, which matters for
  reconnect jitter and multipart boundaries.
- **The WebSocket `close()` takes no close code**, so a client can't send
  4000 ("I intend to resume"). The gateway resumes anyway and handles the
  `INVALID_SESSION` that sometimes follows.
- **An error raised after the main thread has yielded exits with status 0.**
  Only errors raised before the first yield exit 1. `client:run()` always
  yields first, so a service that relies on its exit status should call it
  inside `Discord.main`, which exits 1 explicitly.
- **`process.args[1]` is the script path.** Your own arguments start at
  index 2.

## Licence

MIT. See [LICENSE](LICENSE).
