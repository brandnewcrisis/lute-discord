# Troubleshooting

Each entry is a symptom, what causes it, and the fix. Most problems with a
Discord bot come down to a handful of rules Discord enforces without saying
much. The log usually says more than Discord does, so start there: run with
`LOG_LEVEL=debug` and a `LOG_FILE` if you aren't already.

- [The bot connects, then stops: close code 4014](#the-bot-connects-then-stops-close-code-4014)
- [Close code 4004](#close-code-4004)
- [A 401 at startup](#a-401-at-startup)
- ["The application did not respond"](#the-application-did-not-respond)
- ["Interaction has already been acknowledged"](#interaction-has-already-been-acknowledged)
- [A handler never fires](#a-handler-never-fires)
- [`message.content` is empty](#messagecontent-is-empty)
- [Slash commands don't appear](#slash-commands-dont-appear)
- [Components vanish from webhook messages](#components-vanish-from-webhook-messages)
- ["Invalid Form Body"](#invalid-form-body)
- [429s in the log](#429s-in-the-log)
- [The bot logs nothing under nohup, systemd or Docker](#the-bot-logs-nothing-under-nohup-systemd-or-docker)
- [The process won't exit after `stop()`](#the-process-wont-exit-after-stop)
- [A permission check disagrees with Discord](#a-permission-check-disagrees-with-discord)
- [Ids that are almost right](#ids-that-are-almost-right)
- [A Components V2 message is rejected for having content or embeds](#a-components-v2-message-is-rejected-for-having-content-or-embeds)

## The bot connects, then stops: close code 4014

```text
INFO	using privileged intent(s): messageContent -- these must be enabled under ...
ERROR	shard 0: disallowed intents -- enable the privileged intents you asked for under Bot > Privileged Gateway Intents in the developer portal (close code 4014)
ERROR	shard 0 gave up: disallowed intents -- ...
INFO	shutting down
could not stay connected: disallowed intents -- ...
```

**Cause.** You asked for a privileged intent (`guildMembers`,
`guildPresences` or `messageContent`) that isn't switched on for your
application. Discord doesn't degrade gracefully here. It closes the socket
with 4014 on every attempt, so the client stops rather than looping, and
`run()` raises `could not stay connected: <reason>`. Catch that if a
supervisor needs a non-zero exit status: an error that escapes `run()` exits
with status 0 in Lute 1.0.0 (see
[deploying.md](deploying.md#clientrun-and-clientlogin)).

**Fix.** Enable the intent under **Bot > Privileged Gateway Intents** in the
developer portal, or remove it from `intents`. Once a bot is in 100 or more
servers, privileged intents also need Discord's approval through bot
verification, and the switch alone isn't enough. See
[events.md](events.md) for which events need which intent.

## Close code 4004

```text
ERROR	shard 0: authentication failed -- the bot token is wrong or has been reset (close code 4004)
```

**Cause.** The gateway rejected the token. At startup, a bad token usually
fails earlier, as a [401](#a-401-at-startup) from the REST check the client
makes before connecting. A 4004 typically means the token was reset while
the bot was running, and the next reconnect failed.

**Fix.** Copy a new token from **Bot > Reset Token**, update your
environment or `.env`, and restart. The client never retries a 4004:
reconnecting in a loop with a bad token is how a token gets flagged.

## A 401 at startup

```text
Discord 401 (0) on GET /gateway/bot: 401: Unauthorized
  the bot token is invalid or has been reset; copy a fresh one from the developer portal (Bot > Reset Token)
```

**Cause.** Discord didn't accept the token. In order of likelihood:

- It's the wrong value: the application's client secret or public key from
  the **OAuth2** or **General Information** page, instead of the token from
  the **Bot** page.
- It has been reset since you copied it. Resetting invalidates the old one
  immediately.
- It has `Bot ` in front. The library adds that prefix itself, so it ends
  up as `Bot Bot ...`.
- Stray quotes or whitespace from copying.
- The variable you think you set isn't the one being read. `Env` gives the
  real environment precedence over `.env`, and treats an empty value as
  unset ([utilities.md](utilities.md#env)).

**Fix.** Reset the token, paste it into `.env` with nothing around it, and
restart. If the path in the message is `/applications/@me`, the failure came
from `client:deploy()`, which runs before `run()`. It's the same fix.

## "The application did not respond"

**Cause.** Discord gives the bot **three seconds** to send the first
response to an interaction. Miss that and the user sees this message, and
the interaction's token is invalid from then on. Common reasons:

- The handler does something slow (an API call, a file read, a chain of
  requests) before its first `reply`. The log warns when a first response
  goes out late:
  `interaction 123... answered after 3.4s -- the token may already be dead; defer() first for slow work`.
- The bot isn't running, or it's still connecting. Interactions that arrive
  while no shard is connected go nowhere.
- Something is blocking the whole process. Lute runs your handlers on one
  thread, and a tight CPU loop that never yields stalls every handler, and
  the heartbeat with them.

**Fix.** Call `ix:defer()` first in any handler that might take more than a
second. That's the first response, and it buys fifteen minutes. `ix:reply`
afterwards edits the placeholder for you. See
[interactions.md](interactions.md#the-three-second-rule).

"Unknown interaction" (error 10062) from a reply has the same cause: the
token had already expired.

## "Interaction has already been acknowledged"

**Cause.** Two responses were sent for one interaction. The `Interaction`
wrapper tracks state and turns a second `reply` into a follow-up, so inside
one process this is rare. When it does happen, the usual reason is **two
copies of the bot running at once**: an old process you forgot about, a
`nohup` from yesterday, a second machine. Discord sends each interaction to
every connected copy, one answers first, and the other gets this error.

The other cause is mixing the wrapper with the raw routes: calling
`client.api.interactions.createResponse` yourself on an interaction the
wrapper already answered.

**Fix.** Find and stop the other process (`ps aux | grep lute`). With
`LOG_LEVEL=debug`, each copy logs every command and click it handles, which
shows which one is answering. Use `ix:reply`, `ix:defer` and
`ix:update` rather than the raw routes.

## A handler never fires

Work through these in order:

1. **A missing intent.** Intents decide which events Discord sends at all.
   `messageCreate` needs `guildMessages` (and `directMessages` for DMs),
   reactions need `guildMessageReactions`, `guildMemberAdd` needs the
   privileged `guildMembers`, and so on. Nothing warns you: the event just
   never arrives. Interactions are the exception, and arrive whatever
   intents you ask for. [events.md](events.md) has the full list.
2. **The event name.** Listeners use camelCase names: `messageCreate`,
   `guildMemberAdd`. `client:on("MESSAGE_CREATE", ...)` and
   `client:on("message", ...)` register fine and never fire. To see what
   is arriving, listen to `raw`, which receives every dispatch as
   `(eventName, data)`.
3. **The routing prefix.** `client:component(prefix, fn)` matches component
   `custom_id`s that *start with* `prefix`, and `client:modal` does the
   same for modals. A button with id `Vote:yes` doesn't match `vote:`.
   When prefixes overlap, the longest wins. A click nothing matches is
   acknowledged silently, with a `debug` line:
   `unhandled component "..."`.
4. **A collector took it.** An active collector on the same message sees
   component clicks before the prefix routes do.
5. **The command path.** `client:command("role add", fn)` handles that
   subcommand, and `client:command("role", fn)` handles all of `/role`'s
   subcommands that don't have their own. A command with no handler at all
   replies "`/name` is not wired up on this bot", so if you see that, the
   name you registered doesn't match the one you deployed.

## `message.content` is empty

**Cause.** Message text is behind the privileged `messageContent` intent.
Without it, `content`, `embeds`, `attachments` and `components` arrive empty
for most messages. The exceptions are DMs, messages that mention the bot,
and the bot's own messages. The rest of the event (author, channel, id)
still arrives, which is why this looks like a bug rather than a missing
permission.

**Fix.** If you need the text, enable **Message Content Intent** in the
developer portal and add `"messageContent"` to `intents`. If you're
building commands, use slash commands, which need no intent at all. To
filter messages, AutoMod rules (`client.api.guilds.createAutoModRule`) run on
Discord's side without the intent.

## Slash commands don't appear

- **Global commands take time.** A global deploy can take up to an hour to
  show up in every client. While developing, deploy to a guild with
  `client:deploy(commands, guildId)`, which is instant.
- **Guild and global are separate lists.** Deploying to a guild doesn't
  touch the global list, and the reverse. If you moved from guild to
  global, the old guild commands are still there too, and commands show up
  twice. Clear them with `client:deploy({}, guildId)`.
- **The client is stale.** Discord's desktop client caches the command
  list. Press Ctrl+R (Cmd+R on macOS) to reload it.
- **The command is hidden on purpose.** `defaultPermissions(...)` hides a
  command from members without those permissions, and with no arguments
  from everyone but administrators. `guildOnly()` hides it in DMs.
- **The deploy failed or went elsewhere.** A successful deploy logs
  `deployed N command(s) to guild <id>` or `... globally`. Check which one
  you got, and that the guild id is the server you're looking at.
- **The invite was missing a scope.** Old invite links without the
  `applications.commands` scope added the bot but not its commands.
  Re-invite with the scope. You don't need to kick the bot first.

## Components vanish from webhook messages

**Cause.** A webhook that isn't owned by an application (one a user created
in channel settings, rather than one your bot created) drops `components`
from a message without an error, unless the request sets
`with_components=true`. Even then, only non-interactive components are
allowed on such a webhook, such as link buttons and Components V2 layout,
because there's no application to receive the clicks.

**Fix.** `Discord.Webhook` always sets `with_components`. If you call
`api.webhooks.execute` or `editMessage` directly, pass
`{ with_components = true }` in the query argument. For buttons that do
something, send the message through the bot, or through a webhook the bot
created with `api.webhooks.create`. See [rest.md](rest.md#webhooks).

## "Invalid Form Body"

```text
Discord 400 (50035) on POST /channels/123/messages: Invalid Form Body
  embeds.0.fields.2.value: This field is required
```

**Cause.** Discord rejected a field in the body. The lines under the message
are the flattened field errors: a JSON path and what's wrong with it. In a
handler, `err:fieldErrors()` gives the same lines as a list.

The builders check most of what triggers this before the request is sent,
and fail on your line with a readable message: embed lengths, the 10-embed
and 6000-character limits across a message, command names and
descriptions, option counts and constraints, component layout rules, empty
messages, Components V2 conflicts, bulk-delete counts and ages, and CDN
image sizes. What's left for Discord to reject is usually one of:

- message `content` over 2000 characters (use `Util.truncate`),
- a malformed URL in an embed or button,
- an id passed as a number rather than a string (see
  [below](#ids-that-are-almost-right)),
- a field Discord has changed since this library was written.

**Fix.** Read the path, compare the field with
[Discord's API reference](https://discord.com/developers/docs), and fix
the value. [rest.md](rest.md#errors) covers `ApiError` in detail.

## 429s in the log

```text
WARN	rate limited on POST /channels/:id/messages:channels:123 for 1.2s (scope user)
```

**Cause.** A request hit a rate limit. The library waits and retries, so an
occasional line like this is normal and needs nothing from you. The scope
says whose limit it was: `user` is your bot's own, `shared` is a limit on the
resource that other bots and users count toward too, and `global` is your
bot's overall request rate.

**It needs attention when** the same bucket shows up constantly, or you see
`globally rate limited`. That's a loop sending more than it needs to.

**Fix.** Send less. Use `channels.bulkDeleteMessages` instead of deleting
one by one, edit one message instead of posting many, read from the cache
instead of fetching, and `deploy` commands once per release rather than on
every start. Check permissions before acting. A loop that keeps retrying a
403 counts toward Discord's limit of 10,000 invalid requests per ten
minutes, after which it blocks your IP for a while. See
[rest.md](rest.md#rate-limits).

## The bot logs nothing under nohup, systemd or Docker

**Cause.** Lute block-buffers stdout when it isn't a terminal. The log lines
exist, but they sit in a buffer until it fills or the process exits, so a
quiet bot (or one that crashed) shows nothing at all.

**Fix.** Set `LOG_FILE` and pass it to the client as
`logFile = env:get("LOG_FILE")`. Every log line is then also written
straight to that file. Your own `print`s stay buffered, so log through
`Discord.Log`. See [deploying.md](deploying.md#logs).

## The process won't exit after `stop()`

**Cause.** Something still has a timer pending. Lute timers can't be
cancelled, and a pending one keeps the process alive until it fires. The
library's own waits are all sliced so they end promptly on `stop`, so the
usual culprit is code of yours: a `task.delay(3600, ...)`, a `task.wait(600)`
inside a loop, or a `while true do` loop that doesn't check whether the
client is still running.

**Fix.** Replace long waits with `Util.sleepWhile(seconds, function() return
client.running end)`, which wakes within a quarter second of the condition
turning false. Schedule delayed work with a `Scheduler`, and call
`scheduler:stop()` after `run()` returns. See
[deploying.md](deploying.md#graceful-shutdown).

## A permission check disagrees with Discord

Your code says the bot may do something, and Discord answers
`403 (50013) Missing Permissions`, or the reverse. Likely causes:

- **Discord split a permission.** Since 2026-02-23, pinning needs
  `pinMessages`, and `manageMessages` no longer covers it. Discord does
  this every so often. Check the permission the route needs in Discord's
  docs, not the one it used to need.
- **Role hierarchy.** Having the permission isn't enough to act on a member
  whose highest role is at or above the bot's, or on the server owner.
  Discord answers that with the same 50013. Check
  `Permissions.outranks` too.
- **Guild-wide instead of per-channel.** `forMember` ignores channel
  overwrites. For anything done in a channel, use `forChannel`.
- **A thread.** Threads have no overwrites of their own. Compute for the
  parent channel, and check `sendMessagesInThreads` rather than
  `sendMessages`.
- **Stale or missing cache data.** Without the `guilds` intent the cache
  never hears about role and channel changes.

**Fix.** In an interaction handler, use `ix:appPermissions()`. It's
Discord's own computation for that channel, and it can't disagree with
Discord. See [permissions.md](permissions.md).

## Ids that are almost right

Symptoms: "Unknown User" or "Unknown Message" (404) for an id that looks
correct; an id that prints as `1.7592884729911706e+17`; two ids that should
be equal comparing unequal; a user shown the wrong default avatar; a guild
routed to the wrong shard.

**Cause.** An id went through `tonumber`. Discord ids are 64-bit, and a Luau
number holds integers exactly only up to 2^53, so `tonumber` rounds the last
few digits. The result is a different, plausible-looking id. Permission
strings have the same problem, sooner or later.

**Fix.** Keep ids as strings everywhere: as table keys, in storage, in
comparisons. Don't compare them with `<`. If you need ordering (which is
by creation time), compare `Discord.Snowflake.timestamp(id)`, or compare
lengths first and then the strings. For permissions, use `Bitfield`
([permissions.md](permissions.md)).

## A Components V2 message is rejected for having content or embeds

```text
a Components V2 message cannot carry content; put the text in Components.text
```

**Cause.** A message with the Components V2 flag shows only its components.
It can't also have `content`, `embeds`, a poll or stickers, and Discord
rejects one that does with a bare 400. The library sets the flag
automatically when your components include a V2-only kind (text, section,
container and the rest), and checks the conflict itself so the error names
the field. The flag is also permanent: once a message is V2, every later
edit is checked the same way.

**Fix.** Move the text into `Components.text(...)`, and the embed's content
into a `Components.container(...)`. To convert an existing legacy message to
V2 by editing it, clear the old fields in the same edit with
`content = Json.null` and `embeds = {}`. See
[components.md](components.md#what-a-v2-message-cant-have).
