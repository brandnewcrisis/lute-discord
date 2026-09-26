# REST

Everything your bot does to Discord, as opposed to hearing from it, is an
HTTP request: sending a message, banning a member, creating a role,
publishing commands. This page covers the REST layer: how to call it, what a
message payload can hold, uploads, embeds, errors, rate limits, webhooks and
CDN URLs.

## Two ways in

Inside a bot, the client already has one:

```luau
client.api.channels.createMessage(channelId, "hello")
```

A script that only needs REST (a cron job, a CI step, a one-off migration)
doesn't need a gateway connection at all. Build the layer yourself:

```luau
local Discord = require("@discord")

local env = Discord.Env.load()

Discord.main(function()
	local api = Discord.Api.new(Discord.Http.new(env:require("DISCORD_TOKEN")))
	local channelId = env:require("ANNOUNCE_CHANNEL_ID")

	local me = api.users.getCurrent()
	local message = api.channels.createMessage(channelId, `Deployed by {me.username}`)
	api.channels.addReaction(channelId, message.id, "✅")
end)
```

`Http` is the transport (auth, rate limits, retries, multipart). `Api` is a
thin map of routes on top of it. `Discord.main` is there so that a failure
prints something useful. See [Errors](#errors) for why that matters.

Every call is synchronous from your point of view: it yields until Discord
answers and returns the decoded body, or `nil` for routes that answer
`204 No Content`. It throws on failure.

## The namespaces

`src/api.luau` has one function per route, grouped by resource, with
Discord's quirks noted on the route they affect. It's written to be read, so
when you want something that isn't below, search that file for the resource
name. Arguments come in the order they appear in the URL, then the body, then
an optional audit-log `reason` last.

Wire fields stay in Discord's `snake_case` (`rate_limit_per_user`,
`parent_id`), so the [official API docs](https://discord.com/developers/docs)
read straight across. Options this library adds itself are `camelCase`
(`deleteMessageSeconds`, `appliedTags`).

### `channels`

Channels, messages, reactions, pins, threads and permission overwrites.

| Call | Notes |
| --- | --- |
| `get(channelId)`, `edit(channelId, patch, reason?)`, `delete(channelId, reason?)` | |
| `createMessage(channelId, payload)` | `payload` is a [`MessageInput`](#message-payloads). |
| `editMessage(channelId, messageId, payload)`, `deleteMessage(channelId, messageId, reason?)` | |
| `getMessages(channelId, { limit?, before?, after?, around? }?)` | `limit` caps at 100. Page back with `before`. |
| `bulkDeleteMessages(channelId, ids, reason?)` | 2 to 100 ids, none older than 14 days. Both are checked before sending, and the error says how many ids were too old. Filter with [`Snowflake.age`](utilities.md#snowflake). |
| `addReaction(channelId, messageId, emoji)` | `emoji` is a character, or `name:id` for a custom one. |
| `getReactions(channelId, messageId, emoji, query?)` | Super reactions are listed separately (`type = Const.ReactionType.BURST`). |
| `pinMessage`, `unpinMessage`, `getPins(channelId, { before?, limit? }?)` | Pinning needs `PIN_MESSAGES`. `getPins` pages by `pinned_at`, not by id. |
| `editPermissions(channelId, overwriteId, overwrite, reason?)` | |
| `createInvite(channelId, options?, reason?)` | |
| `triggerTyping(channelId)` | Shows "Bot is typing…" for about ten seconds. |
| `startThread`, `startThreadFromMessage`, `createForumPost(channelId, name, message, options?)` | A forum post needs a starter message, so it's an argument. |

### `guilds`

Servers: members, roles, bans, emoji, audit log, scheduled events, AutoMod.

| Call | Notes |
| --- | --- |
| `get(guildId, withCounts?)`, `edit(guildId, patch, reason?)` | |
| `getChannels(guildId)`, `createChannel(guildId, options, reason?)` | |
| `getMember(guildId, userId)`, `searchMembers(guildId, name, limit?)` | Search needs no privileged intent. `listMembers` does. |
| `editMember(guildId, userId, patch, reason?)` | Nicknames, roles, timeouts (`communication_disabled_until`). |
| `addMemberRole`, `removeMemberRole(guildId, userId, roleId, reason?)` | |
| `kickMember(guildId, userId, reason?)` | |
| `banMember(guildId, userId, { deleteMessageSeconds? }?, reason?)`, `unbanMember`, `bulkBan` | `deleteMessageSeconds` is 0 to 604800. |
| `getRoles`, `createRole`, `editRole`, `deleteRole`, `editRolePositions` | |
| `getAuditLog(guildId, query?)` | |
| `getAutoModRules`, `createAutoModRule`, ... | Filtering on Discord's side, without the `messageContent` intent. |
| `getScheduledEvents`, `createScheduledEvent`, ... | |
| `createEmoji(guildId, { name, image, roles? }, reason?)` | `image` is a `data:` URI. See [`Util.dataUri`](utilities.md#util). |

### The rest

| Namespace | What it's for | Representative calls |
| --- | --- | --- |
| `users` | The bot's own user, and DMs. | `getCurrent()`, `get(userId)`, `createDm(userId)`, `getGuilds(query?)`, `leaveGuild(guildId)` |
| `applications` | Commands, application emoji, role-connection metadata. | `getCurrent()`, `bulkOverwriteGlobalCommands(appId, commands)`, `bulkOverwriteGuildCommands(appId, guildId, commands)`, `getEmojis(appId)` |
| `interactions` | Low-level interaction responses. You normally use the `Interaction` wrapper instead ([interactions.md](interactions.md)). | `createResponse(id, token, type, data?, files?)`, `editOriginalResponse(appId, token, payload)`, `createFollowup(appId, token, payload)` |
| `webhooks` | Creating, editing and executing webhooks. See [Webhooks](#webhooks). | `create(channelId, options)`, `execute(id, token, payload, query?)`, `editMessage(...)` |
| `invites` | Looking up and revoking invites, and invite target users. | `get(code, withCounts?)`, `delete(code, reason?)` |
| `gateway` | Gateway URL and session budget. | `getBot()` (see [deploying.md](deploying.md#restarts-and-the-session-budget)) |
| `polls` | Poll results. | `getAnswerVoters(channelId, messageId, answerId, query?)`, `endPoll(channelId, messageId)` |
| `stickers` | Standard sticker packs and guild stickers. | `get(stickerId)`, `list(guildId)`, `create(guildId, options, reason?)` |
| `soundboard` | Soundboard sounds. | `listDefault()`, `list(guildId)`, `send(channelId, soundId, sourceGuildId?)` |
| `stageInstances` | Live stages, keyed by the stage *channel* id. | `create(options)`, `get(channelId)`, `delete(channelId)` |
| `voice` | Voice regions and voice states. There's no audio: Lute has no UDP socket. | `listRegions()`, `getUserState(guildId, userId)` |
| `monetization` | SKUs, entitlements, subscriptions. | `listSkus(appId)`, `listEntitlements(appId, query?)` |
| `cdn` | URL builders. Makes no requests. See [CDN URLs](#cdn-urls). | `userAvatar(user, options?)`, `guildIcon(guildId, hash, options?)` |

### Routes that aren't wrapped

`api.http` is the underlying `Http`. If Discord ships a route before this
library does, call it directly and still get rate limiting and retries:

```luau
local lobby = api.http:get(`/lobbies/{lobbyId}`)
```

`get`, `post`, `patch`, `put` and `delete` take `(path, options?)`, where
`options` can hold `query`, `body`, `files`, `reason` and `headers`, plus:

| Option | Meaning |
| --- | --- |
| `list = true` | The body is a JSON array. An empty top-level body otherwise goes out as `{}`, because `@std/json` writes an empty table as `[]` and nearly every Discord body is an object. |
| `attachmentsPath` | Where the message that owns the uploads sits inside `body`, when it isn't the body itself: `"data"` for an interaction callback, `"message"` for a forum post. Discord reads `attachments` (and each file's description) from there. |
| `interaction = true` | An interaction route under a webhook-shaped path. It skips the global limit and the 45-per-second window, which interaction routes are exempt from. `/interactions/...` paths are recognised without it. |
| `form` | `{ fields?, files? }`, for the few routes that take a plain multipart form instead of `payload_json`. Can't be combined with `body` or `files`. |

## Message payloads

Every route that creates or edits a message takes a `MessageInput`: either a
string, or a table of message fields. (Samples from here on assume
`local Embed = Discord.Embed`, `local Payload = Discord.Payload` and
`local Json = Discord.Json`.)

```luau
-- A bare string is shorthand for { content = ... }.
api.channels.createMessage(channelId, "Just text")

api.channels.createMessage(channelId, {
	content = "Nightly build finished",
	silent = true,
	embed = Embed.new():setTitle("Build 412"):setColor("#57F287"),
})
```

The table uses Discord's field names, plus a few conveniences that are
translated before the request goes out:

| Field | Becomes | Why it exists |
| --- | --- | --- |
| `ephemeral = true` | the `EPHEMERAL` flag (64) | Only meaningful on interaction replies. Nobody remembers the bit. |
| `silent = true` | the `SUPPRESS_NOTIFICATIONS` flag (4096) | Posts without a push notification. |
| `embed = e` | `embeds = { e }` | The singular is what people type. |
| `allowedMentions = ...` | `allowed_mentions` | See below. |
| `v2 = true` | the `IS_COMPONENTS_V2` flag | See [components.md](components.md). |

Builders (`Embed`, the component and command builders) and plain tables are
interchangeable anywhere a payload is accepted. Anything with a `toJSON`
method is unwrapped.

A new message with nothing to show (no content, embeds, components, files,
poll, stickers or attachments) is rejected before it's sent, because
Discord's own error for that doesn't say which field was empty. A forward
(`message_reference` with `type = 1`) counts as content, since the
forwarded message is the whole point. Edits are exempt: an edit changes only
the fields it names, so `{ components = {} }` strips a message's buttons,
and `{ embeds = {} }`, `{ content = Json.null }` and `{ flags = 4 }` (hide
the embeds) are all valid on their own. The edit routes and the
`Interaction` wrapper mark their payloads as edits for you. If you build a
body yourself with `Payload.message`, pass `{ edit = true }` for an edit.

A payload with Components V2 content is checked too: it can't also carry
`content`, `embeds`, a poll or stickers. So are the message-wide embed
limits: at most 10 embeds, and 6000 characters across all of them. Content
over 2000 characters is **not** checked; Discord rejects it with a 400. Trim
user input with [`Util.truncate`](utilities.md#util).

### Mentions

Unless you say otherwise, a message pings everyone it mentions, including
`@everyone` if the text contains it and the bot has permission. Anything that
echoes user input should switch pings off:

```luau
api.channels.createMessage(channelId, {
	content = `Suggestion: {userInput}`,
	allowedMentions = Payload.NO_MENTIONS,
})
```

`Payload.NO_MENTIONS` is `{ parse = {} }`: mentions still render as names,
but nobody is notified, users, roles and `@everyone` alike. `Payload.allowedMentions` builds the precise
version. Pass booleans to allow whole categories (`users`, `roles`,
`everyone`), or id lists to allow exactly those:

```luau
-- Names both roles; pings only the first.
api.channels.createMessage(channelId, {
	content = "<@&111111111111111111> <@&222222222222222222>",
	allowedMentions = Payload.allowedMentions({ roleIds = { "111111111111111111" } }),
})
```

The two forms don't mix (Discord rejects a category in `parse` that also
has an id list), so where both are given the id list wins.

`allowedMentions` exists as an alias because the camelCase spelling is the
one people write, and an unknown key is passed through untouched. Discord
ignores a field it doesn't recognise, so without the alias the message would
ping everyone it mentions. That fails silently, and in the expensive
direction.

## File uploads

Put files in `files`. Each one is `{ name, data, contentType?, description? }`,
where `data` is a string or a `buffer`. The request becomes
`multipart/form-data` automatically.

```luau
local handle = fs.open("chart.png", "r")
local bytes = fs.read(handle)
fs.close(handle)

local message = api.channels.createMessage(channelId, {
	embed = Embed.new():setTitle("Weekly activity"):setImage("attachment://chart.png"),
	files = {
		{ name = "chart.png", data = bytes, contentType = "image/png", description = "Messages per day" },
	},
})
```

`attachment://<name>` refers to an upload in the same request, by filename.
That's how an embed image or a Components V2 media item shows a file you're
uploading rather than one already hosted somewhere. `contentType` defaults to
`application/octet-stream`. Set it for images, or Discord may not render them
inline. `description` becomes the attachment's alt text.

### Adding files on edit

An edit that carries `files` and no `attachments` list keeps the files
already on the message and appends the new ones. The library leaves
`attachments` out of the request, which is how Discord knows to append.

`attachments` is the list of existing files to keep. Pass it and only those
survive, plus the new uploads, whose entries the library adds itself. That's
how you drop or replace a file:

```luau
local csv: Discord.File = { name = "data.csv", data = "day,count\nmon,12\n", contentType = "text/csv" }

-- Adds data.csv. Whatever was attached stays.
api.channels.editMessage(channelId, message.id, {
	content = "Updated with the raw data",
	files = { csv },
})

-- Keeps only the first existing file, and adds data.csv.
api.channels.editMessage(channelId, message.id, {
	attachments = { { id = message.attachments[1].id } },
	files = { csv },
})

-- Removes every attachment.
api.channels.editMessage(channelId, message.id, { attachments = {} })
```

One exception: a file's `description` can only travel in the `attachments`
list. So when a new file has a `description` and you pass no keep-list, the
list has to be sent, and it names only the new uploads: **the message's
existing files are removed.** The library logs that at debug level. To keep
them, list them in `attachments` as above.

An edit without `files` and without `attachments` leaves attachments alone.

A few routes take images as a `data:` URI in the JSON body instead of an
upload: emoji, avatars, guild icons, soundboard sounds. Use
`Util.dataUri("image/png", bytes)` for those. `stickers.create` is the one
route that takes a plain form, and it handles that itself.

## Embeds

`Discord.Embed` builds embeds and checks Discord's length limits in each
setter. Discord reports a violation as a 400 naming a JSON path
(`embeds.0.fields.12.value`) rather than the limit, and by then your stack
trace points at the HTTP layer. The builder fails on the line that set the
value.

```luau
local function profile(user: Discord.User): Discord.Embed
	return Embed.new()
		:setTitle(user.username)
		:setColor(Discord.Color.BLURPLE)
		:setThumbnail(Discord.Api.cdn.userAvatar(user, { size = 256 }))
		:addField("Created", Discord.Util.timestamp(Discord.Snowflake.timestamp(user.id), "D"), true)
		:addTrimmedField("Bio", "something long from the user", false)
		:setFooter("Looked up just now")
		:setTimestamp()
end
```

| Setter | Limit |
| --- | --- |
| `setTitle(text)` | 256 characters |
| `setDescription(text)` | 4096 |
| `addField(name, value, inline?)` | name 256, value 1024, at most 25 fields; an empty value is an error |
| `setAuthor(name, iconUrl?, url?)` | name 256 |
| `setFooter(text, iconUrl?)` | 2048 |
| whole embed, checked in `toJSON` | 6000 across title, description, fields, footer and author |

Limits count characters (UTF-8 code points), not bytes, and are available as
`Embed.LIMITS`. The rest:

- `setColor` takes a number, a `Discord.Color` entry, `"#rrggbb"` or `"#rgb"`.
  Anything else is an error rather than a silent fallback.
- `setTimestamp(unixSeconds?)` defaults to now. The client renders it in the
  viewer's timezone.
- `setUrl`, `setThumbnail` and `setImage` take URLs, including
  `attachment://` ones.
- `addTrimmedField` truncates instead of throwing, for values that come from
  users. `addBlankField(inline?)` adds an invisible spacer.
- `Embed.new(init?)` accepts an existing embed table to start from, and
  `embed:length()` returns the count Discord uses.

Discord's 6000-character budget applies to the sum of all embeds in a
message, and a message holds at most 10 embeds. `toJSON` checks one embed,
and the payload check covers the rest before sending: it adds up every
embed in the message with `Embed.measure(embed)`, which counts a plain
embed table the same way `embed:length()` counts a builder.

## Audit-log reasons

Most moderation and management routes take an optional `reason` as their
last argument. It shows in the server's audit log next to the action, which
is the only record a moderator later has of *why* the bot did something:

```luau
api.guilds.kickMember(guildId, userId, `Kicked by {moderator.username}: spam`)
api.guilds.banMember(guildId, userId, { deleteMessageSeconds = 86400 }, "Raid account")
```

It travels as the `X-Audit-Log-Reason` header and is percent-encoded for
you, so newlines and non-ASCII text are fine. Discord caps it at 512
characters. When a bot acts for a user, put the user's name in the reason.
Otherwise the audit log attributes everything to the bot.

## Errors

A failed request throws an `ApiError`, the module exported as
`Discord.Error`.

| Field | Meaning |
| --- | --- |
| `status` | The HTTP status. `0` means the request never got an answer (DNS, TLS, connection reset). |
| `code` | Discord's JSON error code, e.g. `50013` Missing Permissions, `10008` Unknown Message. `0` when there was none. |
| `message` | Discord's message, or `HTTP <status>`. |
| `errors` | The raw nested field-error object from a 400, if any. |
| `method`, `path` | The request that failed. |
| `retryAfter` | Seconds, on a 429 that exhausted its retries. |

`tostring(err)` gives one readable line, plus a line per invalid field:

```text
Discord 400 (50035) on POST /channels/123/messages: Invalid Form Body
  embeds.0.fields.2.value: This field is required
```

`err:fieldErrors()` returns those per-field lines as a list. Discord nests
field errors by JSON path (`{"embeds":{"0":{"fields":...}}}`), and without
flattening, a log line only tells you that something, somewhere, was invalid.

Three predicates tell failures apart without reading status codes:

```luau
local ApiError = Discord.Error

local ok, err = pcall(function()
	api.channels.deleteMessage(channelId, messageId)
end)
if not ok then
	if ApiError.isUnknownResource(err) then
		-- 404: already deleted. Usually a race, not a fault.
	elseif ApiError.isForbidden(err) then
		-- 403: the bot lacks a permission.
		print("I need Manage Messages in that channel")
	elseif ApiError.is(err) then
		local e = err :: Discord.ApiError
		print(e.status, e.code, e.message)
		for _, line in e:fieldErrors() do
			print(line)
		end
	else
		error(err, 0) -- a bug in your own code; don't swallow it
	end
end
```

### Why errors throw

A bot has one sensible place to handle "Discord said no": the handler that
started the work. Returning `(ok, err)` from every call would make each call
site check and forward it, and most would forget. So calls throw, and the
client runs every command, component and event handler under `xpcall`. A
throw costs one failed command, logs a traceback, and tells the user
"Something went wrong" if the interaction hasn't been answered yet. It never
takes down the process. Use `pcall` only where you have something better to
do, like the 404 above.

Builders and routes that can spot a mistake before sending (an embed field
over 1024 characters, 101 ids to bulk-delete) throw a plain string error
pointing at your line, not an `ApiError`. The builders (commands,
components, embeds, payloads and the interaction wrapper) raise the error
at the first stack frame outside the library, so the location is your line
even when the check runs several calls deep, such as the payload check
inside `ix:reply`.

### Scripts: use `Discord.main`

Lute's top level prints nothing for an uncaught error that is a table. You
get a stack trace with no message, so a 401 from a stale token looks like a
crash with no explanation. `Discord.main(fn)` runs `fn`, and if it throws,
logs the message and traceback and exits with status 1. Wrap the body of any
script that calls the API outside a client handler.

`client:deploy()`, `client:login()` and `client:run()` don't need it for
the message. They convert startup failures to plain text themselves, and
add the likely cause to a 401. The exit status is another matter: an error
that escapes `run()` or `login()` exits with status 0, so wrap those if
anything reads the status. See
[deploying.md](deploying.md#clientrun-and-clientlogin).

## Rate limits

Usually you don't have to do anything. Requests wait their turn, 429s are
retried, and the only visible effect is that a burst of calls takes a little
longer. What follows is how it works, so you can tell a normal log line from
a real problem.

**Buckets are learned, not configured.** Discord limits requests per
*bucket*, and a bucket isn't a route: several routes can share one, and it
only tells you which one a request landed in via the `x-ratelimit-bucket`
header on the response. The library maps each route to its bucket as the
headers arrive. Until it knows, the route is its own provisional bucket,
which errs toward waiting rather than toward a 429.

**Keyed per major parameter.** A route's key is its method and path with ids
collapsed (`/channels/:id/messages/:id`), except the first id after
`/channels` or `/guilds`, which stays literal, and for `/webhooks` the id
plus the token, since Discord limits a webhook per token. Discord gives each
channel, guild and webhook its own allowance within a shared bucket, so
flooding one channel never slows posting in another. Interaction follow-ups
are webhook routes, so each interaction token gets its own bucket. Buckets
that are idle and not waiting out a limit are swept from time to time, so
one per interaction doesn't add up to a leak.

**One request in flight per bucket.** Requests to the same bucket run one at
a time, so the headers from one response are applied before the next request
decides whether to wait. Different buckets run concurrently. Waits use the
`x-ratelimit-reset-after` duration and a monotonic clock, never the
wall-clock reset timestamp, so a machine whose clock is a few seconds off
behaves the same.

**The global limit.** Discord allows about 50 requests per second per bot
across all routes. The library keeps itself under 45 so it never trips it.
If a global 429 arrives anyway, every bucket pauses, not just the one that
was hit. Interaction responses and follow-ups are exempt from the global
limit, so they skip both the pause and the 45-per-second window: a reply
queued behind a burst of other requests could otherwise miss its three
seconds.

**Retries.** A 429 is retried after the time Discord gives. The pause is
parked on the bucket before its lock is released, so queued requests wait
rather than walking into the same 429. A 5xx, or a request that got no
answer, is retried with jittered exponential backoff. Transport failures
are only retried for `GET`, `HEAD`, `PUT` and `DELETE`: a `POST` that timed
out may have landed, and retrying it could post twice. After `maxRetries`
the call throws an `ApiError`.

**Deleting messages has its own bucket.** Discord limits `DELETE` on a
message much more tightly than other operations on the same route. The
library keys it separately, so a purge command doesn't slow ordinary edits.
For more than a handful of messages, `channels.bulkDeleteMessages` is one
request instead of many.

**What you need to do.** Nothing, usually. Occasional `rate limited on ...`
warnings in the log are normal and already handled. The case that needs
action is a steady stream of them, or requests Discord refuses (401, 403,
429). Discord blocks a bot's IP for a while after 10,000 of those in ten
minutes. A loop that retries a 403 is the classic way to get there, which is
why [permissions.md](permissions.md) is worth reading. `api.http.requestCount`
and `api.http.rateLimitHits` are running totals if you want to watch them.

### `HttpOptions`

`Discord.Http.new(token, options?)` and `Client.new({ http = ... })` accept:

| Option | Default | Meaning |
| --- | --- | --- |
| `maxRetries` | `3` | Retries per request for 429, 5xx and transport failures. |
| `backoffBase` | `0.5` | Seconds. The 5xx/transport backoff is a random delay between 0 and `min(backoffCap, backoffBase * 2^attempt)`. |
| `backoffCap` | `10` | Seconds. |
| `baseUrl` | `https://discord.com/api/v10` | Where requests go. Point it at a mock server, or at a relay. |
| `userAgent` | `DiscordBot (<repo url>, <version>)` | Discord asks for this shape and may block clients that send something unrecognisable. |
| `transport` | Lute's `net.request` | The function that puts a request on the wire. |

### Custom transports

A transport is `(url, { method, body, headers }) -> { status, headers, body }`.
It may yield, and it must throw on a network failure rather than return a
made-up status, because the throw is what the retry logic acts on. Swap it
to log every call:

```luau
local net = require("@std/net")

local http = Discord.Http.new(token, {
	transport = function(url, request)
		local started = os.clock()
		local response = net.request(url, {
			method = request.method :: any,
			body = request.body,
			headers = request.headers,
		})
		print(`{request.method} {url} -> {response.status} in {math.floor((os.clock() - started) * 1000)} ms`)
		return { status = response.status, headers = response.headers, body = response.body }
	end,
})
```

To send traffic through a proxy or relay, rewrite `url` here, or set
`baseUrl` if a prefix change is all you need.

The same seam makes code that calls the API testable without a network.
Return canned responses and record what was sent:

```luau
local sent: { string } = {}
local http = Discord.Http.new("test-token", {
	baseUrl = "https://discord.test/api",
	transport = function(url, request)
		table.insert(sent, `{request.method} {url}`)
		return { status = 200, headers = {}, body = '{"id":"1","channel_id":"2","content":"ok"}' }
	end,
})
local api = Discord.Api.new(http)
```

The library's own test suite drives the rate limiter this way; see
`tests/fakes.luau` for a fuller fake with per-route responders.

## Webhooks

A webhook URL carries its own credential. `Discord.Webhook` drives one from
the URL alone, with no bot token, gateway or application, which makes it
the right tool for alerting and CI:

```luau
Discord.main(function()
	local webhook = Discord.Webhook.fromUrl(env:require("ALERT_WEBHOOK_URL"))
	local message = webhook:send({
		content = "Disk usage at 91%",
		username = "monitor",
		allowedMentions = Payload.NO_MENTIONS,
	})
	webhook:edit(message.id, "Disk usage back to 60%")
end)
```

| Method | Does |
| --- | --- |
| `Webhook.fromUrl(url, options?)` | Parses `discord.com`, `discordapp.com`, `canary.` and `ptb.` URLs, with or without `/api/v10`. |
| `Webhook.new(id, token, options?)` | The same, from the parts. |
| `webhook:send(payload)` | Posts and returns the message. `username` and `avatar_url` in the payload override the webhook's name and picture for that message. |
| `webhook:edit(messageId, payload)`, `webhook:delete(messageId)`, `webhook:fetchMessage(messageId)` | Only for messages this webhook posted. |
| `webhook:info()`, `webhook:modify(patch)`, `webhook:destroy()` | The webhook itself. `destroy` stops the URL working for everyone. |

`options` is `{ threadId?, http? }`. `threadId` posts into a thread, which a
forum or media channel requires unless the payload sets `thread_name` to
start a new post. `http` takes the same [`HttpOptions`](#httpoptions).

`send` always asks Discord to return the message (`wait=true`), because
without it you get a 204 and no id to edit or delete later. It also always
sets `with_components=true`: a webhook not owned by an application
otherwise drops components without an error.

Treat a webhook URL like a bot token. Anyone who has it can post as the
webhook and delete what it posted.

With a bot token, `api.webhooks` covers the rest: `create(channelId,
options, reason?)`, `getChannelWebhooks`, `getGuildWebhooks`, `edit`,
`delete`, and the token routes `execute(id, token, payload, query?)`,
`getMessage`, `editMessage`, `deleteMessage`, `getWithToken`,
`editWithToken`, `deleteWithToken`. The raw `execute` route defaults to
Discord's behaviour, so pass `{ wait = true }` if you want the message
back, and `with_components = true` if the webhook isn't app-owned.

## CDN URLs

`Discord.Api.cdn` (also `api.cdn`) builds image URLs. It never makes a
request.

```luau
local cdn = Discord.Api.cdn

cdn.userAvatar(user)                                -- falls back to the default avatar
cdn.userAvatar(user, { size = 512, format = "webp" })
cdn.userAvatar(user, { animated = false })          -- a still frame of an animated avatar
cdn.defaultAvatar(user)

local icon = guild.icon
if icon ~= nil then
	cdn.guildIcon(guild.id, icon, { size = 128 })
end
cdn.emoji("123456789012345678", true)               -- animated emoji
```

Options are `{ size?, format?, animated? }`:

- `size` must be a power of two from 16 to 4096. Discord answers anything
  else with a 400, so it's an error here.
- `format` is `png`, `jpg`, `jpeg`, `webp` or `gif`. When omitted, an
  animated hash (one starting `a_`) gets `gif` and anything else `png`.
  Asking for `gif` on a still hash is an error.
- `animated = false` forces a still frame. `webp` on an animated hash adds
  `?animated=true`, since the bare extension serves only the first frame.

`userAvatar` returns the default avatar when the user has none.
`defaultAvatar` computes which of the six defaults a user has from their id,
using exact arithmetic on the id string. `tonumber` on a snowflake rounds,
and the rounding hands some users the wrong one. Emoji default to `webp`.

The others: `userBanner`, `memberAvatar`, `memberBanner`, `guildIcon`,
`guildBanner`, `guildSplash`, `guildDiscoverySplash`, `roleIcon`,
`applicationIcon`, `scheduledEventCover`, `sticker` and
`stickerPackBanner`. `guilds.widgetImageUrl(guildId, style?)` builds the
server widget PNG URL the same way.

## JSON

`Discord.Json` is the JSON layer the library uses, and you'll want it for two
things Lute's `@std/json` leaves awkward.

**Setting a field to `null`.** A Luau table can't hold `nil`, so a field you
leave out is simply absent, and on a PATCH, absent means "don't change". To
*clear* something, send `Json.null`:

```luau
api.guilds.editMember(guildId, userId, { nick = Json.null })                         -- remove the nickname
api.guilds.editMember(guildId, userId, { communication_disabled_until = Json.null }) -- end a timeout
api.channels.edit(channelId, { parent_id = Json.null })                              -- move out of its category
```

**Sending `{}`.** An empty Luau table serialises as `[]`, and Discord rejects
`[]` where it expects an object. `Json.object()` (or `Json.object(props)`)
marks a table as an object. `Http` already sends an empty top-level body as
`{}` (unless the request sets `list = true`), so you only need it for an
empty object nested inside a body you build by hand.

`Json.encode(value, pretty?)` and `Json.decode(text)` round it out. `decode`
never throws: it returns `nil` plus an error message on bad input. It also
converts JSON `null` to `nil` and strips `@std/json`'s internal object marker,
so decoded payloads iterate like normal tables. Every payload the library
hands you has been through it, which means a field Discord sent as `null`
and a field it left out both read as `nil`.
