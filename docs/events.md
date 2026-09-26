# Events

Slash commands and buttons reach your bot as [interactions](interactions.md).
Everything else Discord tells a bot (a message was posted, a member joined,
a reaction was added, a channel was renamed) arrives as a *gateway event*
over the bot's WebSocket connection. You listen for those with `client:on`.

```luau
--!strict
local Discord = require("@discord")

local client = Discord.Client.new({
	token = Discord.Env.load():require("DISCORD_TOKEN"),
	intents = { "guilds", "guildMessages", "messageContent" },
})

client:on("messageCreate", function(message)
	if message.author.bot then
		return -- never answer bots, including yourself
	end
	if message.content == "!ping" then
		client:reply(message, "pong")
	end
end)

client:run()
```

## Listening

| Method | What it does |
| --- | --- |
| `client:on(event, fn)` | Calls `fn` every time `event` fires. Returns a handle. |
| `client:once(event, fn)` | Calls `fn` the next time only. Returns a handle. |
| `client:off(handle)` | Removes a listener. |
| `client:waitFor(event, filter?, timeout?)` | Yields until `event` fires with arguments `filter` accepts, and returns them, or nil after `timeout` seconds. No timeout means wait forever. |

Each listener runs on its own task, so a slow one doesn't delay the others
or the connection. A listener that throws is logged with a traceback and
reported through the [`error` event](#library-events). The bot keeps running.

### Typed listeners

`on`, `once` and `waitFor` know every event's payload type, and infer the
listener's parameters from the event name. In the example above, `message`
is a `Discord.Message` with no annotation, and `message.author.bot` is
checked. The [reference table](#gateway-event-reference) says which type
goes with which event.

An annotation is still allowed, and it's checked against the event, so a
wrong one is an error (`None of the overloads for function that accept 3
arguments are compatible`):

```luau
client:on("guildMemberAdd", function(event: Discord.GuildMemberEvent) -- fine
	print(`{event.user.username} joined {event.guild_id}`)
end)
-- client:on("guildMemberAdd", function(message: Discord.Message) end) -- type error
```

A name that isn't a known event falls back to an untyped listener,
`(...any) -> ...any`, because `client:emit` with a name of your own is
legitimate.

**One limitation.** In Luau 1.0.0, an operator applied directly to an
unannotated listener parameter fails to typecheck, because the checker can
look at the operator before it has worked out the parameter's type:

```text
Operator '..' could not be applied to operands of types string and unknown
```

`"hi " .. m.author.username` fails this way, and so does `#m.content`.
Property access, string interpolation and function calls are fine:
`` `hi {m.author.username}` ``, `string.len(m.content)` and
`client:reply(m, ...)` all typecheck. The fix is either of:

```luau
-- Annotate the parameter. It's still checked against the event.
client:on("messageCreate", function(m: Discord.Message)
	print("hi " .. m.author.username, #m.content)
end)

-- Or use interpolation instead of `..`.
client:on("messageCreate", function(m)
	print(`hi {m.author.username} ({string.len(m.content)} characters)`)
end)
```

### `waitFor`

`waitFor` suits a short conversation inside a command handler:

```luau
client:command("guess", function(ix: Discord.Interaction)
	local channelId = ix:requireChannelId()
	ix:reply("I'm thinking of a number from 1 to 10. Type your guess.")
	local message: Discord.Message? = client:waitFor("messageCreate", function(m: Discord.Message): boolean
		return m.author.id == ix.user.id and m.channel_id == channelId
	end, 30)
	if message == nil then
		ix:followUp("Too slow.")
	elseif tonumber(message.content) == math.random(1, 10) then
		client:reply(message, "Right!")
	else
		client:reply(message, "Wrong.")
	end
end)
```

That one needs the `guildMessages` and `messageContent` intents, since it
reads what the user typed. A filter that throws counts as "no" and is
logged. It never leaves `waitFor` hanging.

The filter's parameters are inferred from the event name, like a
listener's. `waitFor`'s return is `any`, though: a known name also matches
the untyped fallback, and Luau settles that ambiguity as `any`. Annotate the
local you assign it to, as above (`local message: Discord.Message? = ...`).

### Event names

An event's name is the camelCase form of Discord's gateway name:
`MESSAGE_CREATE` is `messageCreate`, `GUILD_MEMBER_ADD` is
`guildMemberAdd`, and `MESSAGE_REACTION_REMOVE_EMOJI` is
`messageReactionRemoveEmoji`. `Discord.Client.eventName("GUILD_BAN_ADD")`
does the conversion if you ever need it.

A name that isn't a known event is logged as a warning, with the likely
intended name. See [Listener warnings](#listener-warnings).

### Listener warnings

A listener that can never fire is the most common "my handler does
nothing" report, and nothing about it fails. So the client checks each
event name the first time you listen for it, and logs what it finds:

- **A misspelled name**, with a suggestion:
  `no event named "messageCreated"; did you mean "messageCreate"? (ignore
  this if the bot raises it itself with client:emit)`.
- **An event none of whose intents are enabled**:
  `listening for "guildMemberAdd", but the guildMembers intent is not
  enabled, so it will never fire; guildMembers is privileged, so it must
  also be enabled in the developer portal (Bot > Privileged Gateway
  Intents)`. When several intents can deliver the event (`messageCreate`
  comes with `guildMessages` for servers and `directMessages` for DMs), it
  warns only if none of them is enabled, and lists them all.
- **Message events without `messageContent`**, at info level rather than as
  a warning, because many bots are right not to ask for it:
  ``listening for "messageCreate" without the messageContent intent:
  `content` (and embeds, attachments, components) will be empty except in
  DMs and messages that mention the bot``. This covers `messageCreate` and
  `messageUpdate`. See [Message content](#message-content).

Each is logged once per event name. They're warnings, not errors: a custom
event raised with `client:emit` is fine, and a bot may add an intent later
without touching the listener.

Two other startup checks live elsewhere: a [collector](components.md#collectors)
with neither `messageId` nor `filter` logs a warning, and `client:deploy`
warns about [commands and handlers that don't match](commands.md#handler-and-command-mismatches).
To send any of these somewhere other than the log, see
[`Log.setHook`](utilities.md#log).

### What happens to each event

Every gateway event goes through the same steps, in this order:

1. The [cache](#the-cache) is updated.
2. `raw` fires with the gateway name and payload.
3. Interactions are routed to your command, component, modal and
   autocomplete handlers.
4. The camelCase event fires.

So by the time your listener runs, the cache already reflects the event.
In a `guildDelete` listener the guild has already left the cache, so read
what you need from the payload. In `guildMemberRemove` the member is
already gone.

## Library events

These come from the library, not from Discord's event list:

| Event | Arguments | When |
| --- | --- | --- |
| `ready` | `(ready: Discord.Ready)` | Every shard has connected. Fires once per `login` or `run`. |
| `shardReady` | `(shardId: number, resumed: boolean)` | A shard became usable: after its READY (`false`) or after a resume (`true`). |
| `shardResume` | `(shardId: number)` | A shard resumed its session after a reconnect. |
| `shardDisconnect` | `(shardId: number, closeCode: number?)` | A shard's socket closed. It reconnects on its own unless the code was fatal. |
| `resumed` | `(data)` | Discord's RESUMED dispatch, passed through. |
| `error` | `(message: string, context: string)` | A handler or listener threw. |
| `raw` | `(eventName: string, data: any)` | Every dispatch, with Discord's own uppercase name. |
| `interactionCreate` | `(interaction: Types.Interaction)` | Every interaction, after it has been routed to your handlers. |

**`ready`** fires once, when *every* shard has completed its first READY.
For a single-shard bot that's the moment it connects. Its payload is the
READY of the shard that completed the set. (Earlier versions of the library
fired `ready` once per shard. `shardReady` is the per-shard event now.)
`ready` doesn't mean the cache is full. READY lists the bot's servers as
unavailable, and each one's `guildCreate` arrives shortly after. Don't count
guilds in `ready`. Listen to `guildCreate`, or read the cache a little later.

**`error`** receives the error as a string (a traceback, or an `ApiError`'s
message) and a context naming what failed: `"command /tag get"`,
`"component poll:42"`, or the event name for a listener. Everything is already
logged by then. This is the hook for forwarding errors to a log channel or
an error tracker:

```luau
client:on("error", function(message: string, context: string)
	pcall(function()
		client:send("123456789012345678", `**{context}** failed\n\`\`\`\n{string.sub(message, 1, 1800)}\n\`\`\``)
	end)
end)
```

Wrap it in `pcall`. An error hook that throws is logged, but it isn't reported
to itself, so a failure there would otherwise go unnoticed.

`error` only covers handlers and listeners that threw. To forward warnings
as well (the listener warnings, deploy mismatches, rate limits), hook the
log itself with [`Log.setHook`](utilities.md#log).

**`raw`** is for events the library doesn't know about yet, and for
debugging. **`interactionCreate`** is for logging or analytics. Answer
interactions from your handlers, not from here.

## Gateway event reference

The payload type for every gateway event, and the intent that makes Discord
send it. `Discord.X` types come from the main module. `Types.X` types need
one more line:

```luau
local Types = require("@discord/types")

client:on("guildBanAdd", function(ban: Types.GuildBanEvent)
	print(`{ban.user.username} was banned from {ban.guild_id}`)
end)
```

(Luau type paths are one module deep, so `Discord.Types.GuildBanEvent`
isn't valid in a type annotation.)

Intents marked **(privileged)** must also be switched on in the developer
portal. See [Privileged intents](#privileged-intents). "none" means Discord
sends the event whatever intents you ask for.

### Connection and application

| Event | Payload | Intent |
| --- | --- | --- |
| `ready` | `Discord.Ready` | none |
| `resumed` | nothing useful | none |
| `userUpdate` | `Discord.User` (the bot's own user) | none |
| `interactionCreate` | `Types.Interaction` | none |
| `applicationCommandPermissionsUpdate` | `Types.GuildApplicationCommandPermissions` | none |
| `entitlementCreate`, `entitlementUpdate`, `entitlementDelete` | `Types.Entitlement` | none |
| `subscriptionCreate`, `subscriptionUpdate`, `subscriptionDelete` | `Types.Subscription` | none |
| `rateLimited` | `Types.RateLimited` (a gateway request, such as a member fetch, was refused for going too fast) | none |

### Servers, roles, channels and threads

| Event | Payload | Intent |
| --- | --- | --- |
| `guildCreate` | `Discord.Guild` | `guilds` |
| `guildUpdate` | `Discord.Guild` | `guilds` |
| `guildDelete` | `Types.UnavailableGuild` | `guilds` |
| `guildRoleCreate`, `guildRoleUpdate` | `Types.GuildRoleEvent` | `guilds` |
| `guildRoleDelete` | `Types.GuildRoleDelete` | `guilds` |
| `channelCreate`, `channelUpdate`, `channelDelete` | `Discord.Channel` | `guilds` |
| `channelPinsUpdate` | `Types.ChannelPinsUpdate` | `guilds` (servers), `directMessages` (DMs) |
| `threadCreate`, `threadUpdate` | `Discord.Channel` | `guilds` |
| `threadDelete` | `Discord.Channel` (only `id`, `guild_id`, `parent_id`, `type`) | `guilds` |
| `threadListSync` | `Types.ThreadListSync` | `guilds` |
| `threadMemberUpdate` | `Types.ThreadMemberUpdate` | `guilds` |
| `threadMembersUpdate` | `Types.ThreadMembersUpdate` | `guilds`, plus `guildMembers` for other members' changes |
| `stageInstanceCreate`, `stageInstanceUpdate`, `stageInstanceDelete` | `Types.StageInstance` | `guilds` |
| `voiceChannelStatusUpdate` | `Types.VoiceChannelStatusUpdate` | `guilds` |
| `voiceChannelStartTimeUpdate` | `Types.VoiceChannelStartTimeUpdate` | `guilds` |

`guildCreate` fires for every server when the bot connects, when it joins a
new one, and when a server comes back from an outage. `guildDelete` with
`unavailable = true` is an outage: the bot is still a member, and the cache
keeps the guild. Without `unavailable`, the bot was removed.

### Members

| Event | Payload | Intent |
| --- | --- | --- |
| `guildMemberAdd` | `Discord.GuildMemberEvent` | `guildMembers` (privileged) |
| `guildMemberUpdate` | `Discord.GuildMemberEvent` | `guildMembers` (privileged) |
| `guildMemberRemove` | `Types.GuildMemberRemove` | `guildMembers` (privileged) |
| `guildMembersChunk` | `Types.GuildMembersChunk` | none (the answer to a [`fetchMembers`](#fetchmembers) request) |
| `presenceUpdate` | `Types.PresenceUpdate` | `guildPresences` (privileged) |

### Moderation

| Event | Payload | Intent |
| --- | --- | --- |
| `guildBanAdd`, `guildBanRemove` | `Types.GuildBanEvent` | `guildModeration` |
| `guildAuditLogEntryCreate` | `Types.GuildAuditLogEntryCreate` | `guildModeration`, and the bot needs View Audit Log |
| `autoModerationRuleCreate`, `autoModerationRuleUpdate`, `autoModerationRuleDelete` | `Types.AutoModRule` | `autoModerationConfiguration` |
| `autoModerationActionExecution` | `Types.AutoModerationActionExecution` | `autoModerationExecution` (`content` is empty without `messageContent`) |

### Messages

| Event | Payload | Intent |
| --- | --- | --- |
| `messageCreate` | `Discord.Message` | `guildMessages` (servers), `directMessages` (DMs) |
| `messageUpdate` | `Discord.Message` | `guildMessages`, `directMessages` |
| `messageDelete` | `Discord.MessageDelete` | `guildMessages`, `directMessages` |
| `messageDeleteBulk` | `Types.MessageDeleteBulk` | `guildMessages` |
| `messageReactionAdd` | `Discord.MessageReactionAdd` | `guildMessageReactions`, `directMessageReactions` |
| `messageReactionRemove` | `Discord.MessageReactionRemove` | `guildMessageReactions`, `directMessageReactions` |
| `messageReactionRemoveAll` | `Types.MessageReactionRemoveAll` | `guildMessageReactions`, `directMessageReactions` |
| `messageReactionRemoveEmoji` | `Types.MessageReactionRemoveEmoji` | `guildMessageReactions`, `directMessageReactions` |
| `messagePollVoteAdd`, `messagePollVoteRemove` | `Types.MessagePollVoteEvent` | `guildMessagePolls`, `directMessagePolls` |
| `typingStart` | `Types.TypingStart` | `guildMessageTyping`, `directMessageTyping` |

Message events arrive without the message's text unless you also have
`messageContent`. See [below](#message-content).

Reaction events arrive for any message, including ones the bot has never
seen, which is why reaction roles are built on `messageReactionAdd` and not
on a message cache.

### Expressions, invites, integrations, webhooks

| Event | Payload | Intent |
| --- | --- | --- |
| `guildEmojisUpdate` | `Types.GuildEmojisUpdate` | `guildExpressions` |
| `guildStickersUpdate` | `Types.GuildStickersUpdate` | `guildExpressions` |
| `guildSoundboardSoundCreate`, `guildSoundboardSoundUpdate` | `Types.SoundboardSound` | `guildExpressions` |
| `guildSoundboardSoundDelete` | `Types.GuildSoundboardSoundDelete` | `guildExpressions` |
| `guildSoundboardSoundsUpdate` | `Types.GuildSoundboardSounds` | `guildExpressions` |
| `soundboardSounds` | `Types.GuildSoundboardSounds` | none (the answer to a soundboard request) |
| `inviteCreate` | `Types.InviteCreateEvent` | `guildInvites` |
| `inviteDelete` | `Types.InviteDeleteEvent` | `guildInvites` |
| `guildIntegrationsUpdate` | `Types.GuildIdEvent` | `guildIntegrations` |
| `integrationCreate`, `integrationUpdate` | `Types.IntegrationEvent` | `guildIntegrations` |
| `integrationDelete` | `Types.IntegrationDelete` | `guildIntegrations` |
| `webhooksUpdate` | `Types.WebhooksUpdate` | `guildWebhooks` |

### Scheduled events and voice

| Event | Payload | Intent |
| --- | --- | --- |
| `guildScheduledEventCreate`, `guildScheduledEventUpdate`, `guildScheduledEventDelete` | `Types.ScheduledEvent` | `guildScheduledEvents` |
| `guildScheduledEventUserAdd`, `guildScheduledEventUserRemove` | `Types.GuildScheduledEventUserEvent` | `guildScheduledEvents` |
| `voiceStateUpdate` | `Types.VoiceState` | `guildVoiceStates` |
| `voiceChannelEffectSend` | `Types.VoiceChannelEffectSend` | `guildVoiceStates` |
| `voiceServerUpdate` | `Types.VoiceServerUpdate` | none (only after the bot [joins a voice channel](#voice-state)) |

An event Discord adds after this library was written still reaches
`client:on` under its camelCase name, untyped, with a "no event named"
warning. Annotate its parameter as `{ [string]: any }` and read the fields
from Discord's documentation.

## `Discord.Events`

The table above exists in code as `Discord.Events`, and it's what the typed
listeners and the listener warnings are built from:

| Field | What it is |
| --- | --- |
| `Events.REGISTRY` | Every known event name mapped to `{ intents, payload, library? }`: the intents that deliver it (any one is enough; empty means always delivered), the payload type's name, and whether the library raises it rather than Discord. |
| `Events.NAMES` | The same names as a key set. |
| `Events.isKnown(name)` | Whether `name` is an event the library or Discord raises. |
| `Events.suggest(name)` | The known event `name` was probably meant to be, or nil. |
| `Events.missingIntents(event, mask)` | The intents that would deliver `event`, when the intent bitmask `mask` enables none of them. nil when it will arrive, needs no intent, or is unknown. |
| `Events.hasIntent(mask, name)` | Whether intent `name` is set in `mask`. |
| `Events.needsMessageContent(event)` | Whether `event` loses its message text without `messageContent`. |

The types behind `on`, `once` and `waitFor` are there too:
`Events.Handlers` (each event's listener type), `Events.On` and
`Events.WaitFor`. The client's own intents are `client.intents`, as a mask:

```luau
local Events = Discord.Events

local missing = Events.missingIntents("guildMemberAdd", client.intents)
if missing ~= nil then
	print(`welcome messages need one of: {table.concat(missing, ", ")}`)
end
```

## Intents

When a bot connects, it tells Discord which groups of events it wants.
These groups are *intents*. Discord sends nothing outside them, which saves
your bot bandwidth and keeps data a bot doesn't use away from it. Ask for
exactly what your handlers use:

```luau
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds", "guildMessages", "guildMessageReactions" },
})
```

Interactions ignore intents entirely. A bot that only has slash commands and
buttons needs nothing beyond `guilds`, which also feeds the cache.

| Intent | Turns on |
| --- | --- |
| `guilds` | servers, roles, channels, threads, stage instances. Nearly every bot wants this. |
| `guildMembers` (privileged) | member join, update and leave; full member lists |
| `guildModeration` | bans, audit log entries |
| `guildExpressions` | emoji, stickers, soundboard sounds |
| `guildIntegrations` | integrations |
| `guildWebhooks` | webhook changes |
| `guildInvites` | invites created and deleted |
| `guildVoiceStates` | who is in which voice channel |
| `guildPresences` (privileged) | online status and activities |
| `guildMessages` | messages in servers |
| `guildMessageReactions` | reactions in servers |
| `guildMessageTyping` | typing indicators in servers |
| `directMessages` | messages in DMs |
| `directMessageReactions` | reactions in DMs |
| `directMessageTyping` | typing indicators in DMs |
| `messageContent` (privileged) | the text, embeds, attachments and components of messages |
| `guildScheduledEvents` | scheduled events |
| `autoModerationConfiguration` | AutoMod rule changes |
| `autoModerationExecution` | AutoMod actions taken |
| `guildMessagePolls` | poll votes in servers |
| `directMessagePolls` | poll votes in DMs |

An unknown name throws when you create the client. You can also pass a raw
bitmask (`intents = 33281`) if you've computed one elsewhere.

### Privileged intents

Three intents expose data Discord considers sensitive: `guildMembers`,
`guildPresences` and `messageContent`. For those, asking in code isn't
enough. You also have to switch them on in the developer portal under **Bot
> Privileged Gateway Intents**. Once a bot is in 100 or more servers, Discord
also has to approve it, as part of bot verification.

Ask for a privileged intent you haven't been granted and Discord refuses the
connection outright, closing it with code **4014** (disallowed intents). It
doesn't connect you with less data. That's deliberate: a bot that silently
got no member events would have broken welcome messages and nobody would
know why. A refused connection is loud, and it names the cause.

The library helps in two ways. At startup it logs which privileged intents
you asked for and where to enable them. And it treats 4014 as fatal rather
than retrying, since reconnecting can't fix it, and the log says which intent
to enable. After a fatal close, `client:login()` raises
`could not connect: disallowed intents ...`, and `client:run()` stops every
shard and raises `could not stay connected: disallowed intents ...`.

If something supervises your process, make sure that error ends it with a
failure code. In Lute 1.0.0 an error that escapes `run()` exits with status
0 ([deploying.md](deploying.md#clientrun-and-clientlogin) explains why), so
catch it, or run the client inside `Discord.main`, which logs the error and
exits with status 1:

```luau
Discord.main(function()
	client:run()
end)
```

The same applies to the other fatal close codes, such as 4004 (a bad token).
[troubleshooting.md](troubleshooting.md) lists them all.

### Message content

Without `messageContent`, message events still arrive, but `content`,
`embeds`, `attachments`, `components` and `poll` are empty. The exceptions
are messages in DMs with the bot, messages that mention the bot, and the
bot's own messages. Those always have their content. A message shown to your
bot through a message context menu has its content too.

This is why prefix commands (`!ping`) need a privileged intent and slash
commands don't. If your bot only needs to respond when addressed, have it
respond to mentions and skip the intent.

## The cache

`client.cache` keeps what the gateway has told the bot, in memory. Discord
sends every server in full when the bot connects and a change event for
every edit afterwards, so the data arrives anyway. Keeping it turns "what
roles does this server have" from an API request into a table lookup.
[Permission checks](permissions.md) need roles and channel overwrites every
time, so without a cache one moderation command would cost several
requests.

```luau
local guild = client.cache:getGuild(ix.guildId)
local channel = client.cache:getChannel(ix.channelId)
local role = client.cache:getRole("123456789012345678", "234567890123456789")
local roles = client.cache:getRoles("123456789012345678") -- { [roleId]: Role }
local member = client.cache:getMember("123456789012345678", ix.user.id)
local user = client.cache:getUser(ix.user.id)
print(client.cache:stats().guilds, "guilds cached")
```

| Holds | Kept in step by |
| --- | --- |
| Servers | `guildCreate`, `guildUpdate` (replaces the guild, carrying over only the fields sent at connect, such as `member_count` and `channels`, so a field Discord cleared is cleared here too), `guildDelete` |
| Channels and threads | `guildCreate` (including active threads; a fresh one drops channels it no longer lists), `channelCreate/Update/Delete`, `threadCreate/Update/Delete`, `threadListSync` |
| Roles | `guildCreate`, `guildRoleCreate/Update/Delete` (kept in step with `guild.roles` too) |
| Emoji and stickers | on the guild object, replaced by `guildEmojisUpdate` / `guildStickersUpdate` |
| Members | those in `guildCreate`, member events, member chunks, message authors, and interaction users. `guildMemberUpdate` replaces the member, keeping only `deaf`, `mute` and `joined_at`, so a removed nickname or a lifted timeout clears. |
| Users | everyone seen in any of the above |
| The bot's own user | `ready`, `userUpdate`. Also as `client.user`. |

Every lookup returns nil for anything not cached. The maps are plain tables
you can read directly too (`client.cache.guilds`, `client.cache.channels`).
The cached objects are the tables Discord sent, so don't modify them.

What it doesn't hold:

- **Messages.** Fetch them over REST when you need one.
- **Most members.** Discord only sends a large server's full member list
  with the `guildMembers` intent, and holding every member of every server
  takes unbounded memory. The cache has the members it has *seen*. When
  it misses, ask REST:
  `client.cache:getMember(guildId, userId) or client.api.guilds.getMember(guildId, userId)`.
  A REST result isn't cached for you. Call `client.cache:putMember(guildId, member)`
  if you want it kept.
- **Presences and voice states.** Listen to their events and keep what you
  need.

The cache only knows what your intents let through. Without `guilds` it
stays empty. During an outage a server is flagged `unavailable = true` and
keeps its data until Discord sends it again. Nothing is evicted, so on a
very large bot the member and user maps grow for as long as the process
runs.

`cache = false` in the client options turns it off. Only the bot's own user
is still kept, because `client.user` going stale after a rename would be a
bug. Every lookup then returns nil, and anything that relied on it (the
permission helpers included) has to use REST instead.

## `fetchMembers`

```luau
local members, notFound = client:fetchMembers("123456789012345678", { query = "ali", limit = 10 })
```

Asks Discord over the gateway for a server's members, waits for all the
replies, and returns them, caching each one. The second value lists any
`userIds` that weren't found.

| Option | Meaning |
| --- | --- |
| `query` | Members whose username starts with this. `""` (the default) with `limit = 0` means every member. |
| `limit` | Most members to return. 0 means no limit. |
| `userIds` | Look up these members instead of searching (up to 100). |
| `presences` | Include presences. Needs `guildPresences`. |
| `timeout` | Seconds to wait for the last reply. Default 30. |

Everything except a `userIds` lookup needs the `guildMembers` privileged
intent. Without it, Discord sends nothing back and the call times out, with
an error that asks whether the intent is enabled. It also throws before
`login()` or `run()`, and while the server's shard is between connections.
A request made while the shard is still authenticating is queued and sent
right after IDENTIFY or RESUME. For a single member,
`client.api.guilds.getMember` over REST is simpler.

## Shards

A gateway connection (a *shard*) can serve at most 2,500 servers. Past that,
Discord requires a bot to split its servers across several connections, each
getting the events for its share. The library handles this for you: on
connect it asks Discord how many shards to use, starts them all, and spaces
their logins the way Discord requires. Set `shardCount` in the client
options only to override Discord's number.

| Field or method | Meaning |
| --- | --- |
| `client.shardCount` | The number of shards in this run. |
| `client.shards` | The shard objects. |
| `client:shardFor(guildId)` | Which shard (0-based) serves a server: `(guild_id >> 22) % shardCount`. |
| `client:latency()` | Mean heartbeat round trip across shards, in seconds. |

Events from all shards arrive through the same `client:on` listeners.
`shardReady`, `shardResume` and `shardDisconnect` tell you about individual
shards. `shardFor` does its arithmetic on the ID string, because converting a
64-bit ID with `tonumber` loses the low bits and can pick the wrong shard.
[deploying.md](deploying.md) covers running a large bot.

## Presence

The status and activity shown under the bot's name.

```luau
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
	presence = Discord.Client.presence("watching", "for /help"),
})

-- later, from anywhere:
client:setPresence(Discord.Client.presence("playing", "with Lute", { status = "idle" }))
```

`Discord.Client.presence(kind, text, options?)` builds one. `kind` is
`"playing"`, `"streaming"`, `"listening"`, `"watching"`, `"competing"` or
`"custom"` (a custom status that shows `text` alone). `options.status` is
`"online"` (the default), `"idle"`, `"dnd"` or `"invisible"`, and
`options.url` is the Twitch or YouTube URL a `"streaming"` activity links to.

Pass it as the `presence` option to start with it, or call
`client:setPresence` at any time. It applies to every shard, and shards
remember it, so it survives a reconnect instead of reverting to the startup
presence. A change made while a shard is still connecting isn't lost either:
the IDENTIFY that shard sends carries the latest presence. Presence is sent over the gateway, and each connection has a budget
of 120 messages a minute. Changing presence every few minutes is fine.
Changing it every second isn't.

## Voice state

```luau
local guildId, channelId = "123456789012345678", "234567890123456789"

client:updateVoiceState(guildId, channelId) -- join or move
client:updateVoiceState(guildId, channelId, true, true) -- joined, self-muted and self-deafened
client:updateVoiceState(guildId, nil) -- leave
```

`updateVoiceState(guildId, channelId?, selfMute?, selfDeaf?)` moves the
bot's voice *state*: it appears in the channel, or leaves it. It returns
false before the client has connected, or while the server's shard is
between connections. While the shard is still authenticating, the update is
queued and sent right after IDENTIFY or RESUME, and the call returns true.

**Voice audio isn't supported.** Sending or receiving sound needs a UDP
socket and an Opus encoder, and Lute provides neither. The bot can sit in a
channel, silent. That's occasionally useful (showing presence, or vacating
a channel), but music bots and recording aren't possible with this library.
