# Interactions

An *interaction* is Discord telling your bot that a user did something aimed
at it: ran a slash command, used a context menu, typed into an autocomplete
option, clicked a button, picked from a select menu, or submitted a modal.
Every handler you register with `client:command`, `client:component`,
`client:modal` or `client:autocomplete` receives one, as a
`Discord.Interaction`.

An interaction comes with a token, and you answer through that token rather
than through your bot's normal credentials. That's why answering an
interaction needs no permissions in the channel. The user asked, and the
token is Discord's permission slip to answer them.

## The three-second rule

The first response to an interaction must reach Discord within **three
seconds**. If it doesn't, the user sees "The application did not respond"
and the token stops working. Anything you send afterwards fails with
"Unknown interaction".

The reason is that the user's client is waiting. They pressed Enter or
clicked a button and are looking at a spinner. Discord holds that open for
three seconds and no longer. Once you've responded, the token stays valid
for **fifteen minutes**, which is plenty of time for edits and follow-ups.

Three seconds is enough for a reply built from memory. It isn't reliably
enough for a database query, an HTTP request to another service, or a chain
of Discord API calls. For those, **defer** first:

```luau
client:command("activity", function(ix: Discord.Interaction)
	ix:defer() -- the user sees "<bot> is thinking..."
	-- A REST call: usually fast, but nothing guarantees it under three seconds.
	local recent = client.api.channels.getMessages(ix:requireChannelId(), { limit = 100 })
	local people: { [string]: boolean } = {}
	for _, message in recent do
		people[message.author.id] = true
	end
	local count = 0
	for _ in people do
		count += 1
	end
	ix:reply(`{count} people wrote the last {#recent} messages here.`) -- replaces "thinking"
end)
```

Deferring uses up the first response, so the three-second clock stops, and
Discord shows a "thinking" placeholder until you reply. The library logs a
warning when a first response is sent more than 2.5 seconds after the
interaction arrived. If you see that warning, defer.

## Responding

| Method | What it does |
| --- | --- |
| `ix:reply(payload)` | Sends the response. Does the right thing in every state (see below). |
| `ix:replyEphemeral(payload)` | `reply`, visible only to the user who triggered the interaction. |
| `ix:defer(ephemeral?)` | Acknowledges now and shows "thinking". Buys fifteen minutes. |
| `ix:editReply(payload)` | Edits the original response (or the deferred placeholder). Returns the `Message`. |
| `ix:followUp(payload)` | Sends an additional message. Returns the `Message`. |
| `ix:update(payload)` | Components only: edits the message the button or select is on, in place. |
| `ix:deferUpdate()` | Components only: acknowledges the click without changing anything. |
| `ix:showModal(modal)` | Opens a modal form. Must be the first response. |
| `ix:autocomplete(choices)` | Answers an autocomplete interaction with up to 25 suggestions. |
| `ix:fetchReply()` | Fetches the original response as a `Message` (for its `id`, say). |
| `ix:deleteReply()` | Deletes the original response. |

`payload` is a string (shorthand for `{ content = ... }`) or a message table:
`content`, `embeds`, `components`, `files`, `allowed_mentions`, and the
library's own `ephemeral` and `silent` flags. [rest.md](rest.md) covers
payloads, embeds and file uploads in full, and [components.md](components.md)
covers `components`.

### The state rules

Discord allows exactly one *first response* per interaction. After that,
you edit it or send follow-ups, and each of those uses a different API
route. Getting the order wrong produces "Interaction has already been
acknowledged" or "Unknown interaction", and neither says what to do instead.
So the wrapper tracks the state and handles it for you:

| You call | Nothing sent yet | After `defer` | After a reply, `update` or `deferUpdate` |
| --- | --- | --- | --- |
| `reply` | sends the response | edits the placeholder (but see [visibility](#visibility-is-decided-by-the-first-response)) | sends a follow-up |
| `defer` | shows "thinking" | does nothing | does nothing |
| `update` | edits the component's message | edits the original response | edits the original response |
| `deferUpdate` | acknowledges | does nothing | does nothing |
| `showModal` | opens the modal | **throws** | **throws** |

The practical result is that you can write `reply` everywhere. The first
`reply` answers, a `reply` after `defer` fills in the placeholder, and any
`reply` after that becomes a follow-up. `ix.acknowledged` and `ix.deferred`
are there if your own code needs to know the state.

`reply` returns two values: the `Message`, and `true` if it went out as a
follow-up rather than as (or into) the original response. The message is
nil for a first response, because Discord's callback route answers with no
body. When you need that message (to scope a collector to it, say), call
`ix:fetchReply()`. The second value tells you how to edit the message later:
`ix:editReply` for the original response, or
`client.api.interactions.editFollowup` for a follow-up.

### Why a modal can't follow a defer

A modal isn't a message. It's one of the *kinds* of first response, like a
reply or a defer. An interaction has only one first response, so once
you've deferred, the slot is spent and there's nothing left to open a modal
with. The same goes for a reply or an `update`.

This rules out any modal whose contents depend on slow work, because you
can't defer while you fetch. Open the modal straight away with what you
have, and do the slow part when the submission arrives. The submission is a
new interaction with its own three seconds, so it can defer.

`showModal` throws when the interaction was already acknowledged, so the
mistake shows up in your log with an explanation rather than as an API error.

### Visibility is decided by the first response

The first response fixes who can see the original response. Editing a
message can't change its visibility, and Discord ignores the ephemeral flag
on the edit that fills in a deferred placeholder. That has two
consequences:

- **After `defer(true)`, everything that fills the placeholder is
  ephemeral.** A public `reply` stays private, because there's no way to
  widen it. The library logs a debug line, since it's rarely what you meant.
  Send a public `followUp` if you need one.
- **After a public `defer()`, `replyEphemeral` can't edit the placeholder**,
  because that would post the private text for everyone to see. Instead the
  library sends your reply as an ephemeral follow-up and deletes the public
  "thinking" placeholder. The user gets the right result, but the whole
  channel saw "<bot> is thinking..." for a moment.

So decide visibility when you defer:

```luau
client:command("joined", function(ix: Discord.Interaction)
	ix:defer(true) -- private from the start
	local member = client.api.guilds.getMember(ix:requireGuildId(), ix.user.id)
	ix:reply(`You joined this server at {member.joined_at}.`) -- ephemeral, like the defer
end)
```

Follow-ups are separate messages, so each chooses its own visibility.
`ix:followUp({ content = "...", ephemeral = true })` is private whatever came
before.

### Ephemeral messages

An ephemeral message is shown only to the user who triggered the
interaction, marked "Only you can see this". Use them for errors, for
confirmations nobody else needs, and for anything personal. They keep the
channel clean, and a user who mistypes a command isn't embarrassed in
public.

They're also temporary. The user can dismiss one, it doesn't survive a
client reload, and after fifteen minutes the token that could edit it has
expired.

## Reading options

### `opt` and `options`

```luau
local reason = ix:opt("reason", "no reason given") -- value, or the default when absent
local all = ix:options() -- { [name]: value } for every supplied option
```

Absent options simply aren't there, so `ix:opt("reason") or "none"` reads
naturally too. For a user, channel, role or attachment option, the value is
the object's ID.

Both return `any`. An option's type is fixed by the command definition,
which lives somewhere else (often in another file) and which Luau can't see
from the handler. The honest static type would be `string | number |
boolean`, and that would force a type check on every read of a value your
handler already knows the type of. Annotate the local if you want the checker
to hold you to it: `local count: number = ix:opt("count", 1)`.

These read the innermost subcommand's options, so `/config roles add
role:@Mod` gives you `role` directly.

### `get*`: resolved objects

For options that name an object, Discord sends the whole object with the
interaction, so there's nothing to fetch:

| Method | Returns |
| --- | --- |
| `ix:getUser(name)` | `Discord.User?` |
| `ix:getMember(name)` | `Discord.Member?`, with `member.user` filled in |
| `ix:getRole(name)` | `Discord.Role?` |
| `ix:getChannel(name)` | `Discord.Channel?` (a partial channel: ID, name, type, permissions) |
| `ix:getAttachment(name)` | `Discord.Attachment?` |

Each returns nil when the option wasn't supplied. `getMember` also returns
nil when the chosen user isn't a member of the server. A user option can
name anyone Discord lets you pick, including people who left.

### `require*`: required options

A `required = true` option is enforced by Discord: the command can't be sent
without it. But the checker can't see the definition, so it still types
`ix:getUser("user")` as `User?`, and every use needs a nil check you know is
pointless.

The `require*` family is where you tell it once:

| Method | Returns | Throws when |
| --- | --- | --- |
| `ix:requireOpt(name)` | `any` | the option is missing |
| `ix:requireUser(name)` | `Discord.User` | missing, or Discord sent no resolved user |
| `ix:requireMember(name)` | `Discord.Member` | missing, or the user isn't in this server |
| `ix:requireRole(name)` | `Discord.Role` | missing, or no resolved role |
| `ix:requireChannel(name)` | `Discord.Channel` | missing, or no resolved channel |
| `ix:requireAttachment(name)` | `Discord.Attachment` | missing, or no resolved attachment |

If the definition and the handler ever disagree (you made an option
optional and forgot the handler), you get an error naming the option instead
of a nil deep inside your code.

Use `require*` only for things the definition guarantees. `requireMember`
is the exception to watch: "not a member" is something a user can cause by
picking someone who left. That's a user mistake, and it deserves a real
answer rather than the generic error message, so check it with `getMember`:

```luau
client:command("kick", function(ix: Discord.Interaction)
	local guildId = ix:requireGuildId()
	local user = ix:requireUser("user") -- required in the definition
	if ix:getMember("user") == nil then
		ix:replyEphemeral(`{user.username} isn't in this server.`)
		return
	end
	local reason: string = ix:opt("reason", "no reason given")
	ix:defer(true)
	client.api.guilds.kickMember(guildId, user.id, reason)
	ix:reply(`Kicked {user.username}.`)
end)
```

### Where it came from

| Field or method | Type | Notes |
| --- | --- | --- |
| `ix.user` | `Discord.User` | Always set: in a server it's copied from `ix.member.user`. |
| `ix.member` | `Discord.Member?` | Only in servers. Includes `roles` and `permissions`. |
| `ix.guildId` | `string?` | nil in DMs. |
| `ix:requireGuildId()` | `string` | Throws in DMs, with a message suggesting `guildOnly`. |
| `ix.channelId` | `string?` | Set on every interaction a gateway bot receives. |
| `ix:requireChannelId()` | `string` | Narrows the type. It shouldn't ever throw. |
| `ix.locale` | `string?` | The user's client language, for localized replies. |
| `ix:commandPath()` | `string` | `"tag"`, `"tag get"`, `"config roles add"`. |
| `ix.data` | `Types.InteractionData` | The raw `data` object, for anything not wrapped. |
| `ix.raw` | `Types.Interaction` | The whole payload Discord sent. |

`requireGuildId` pairs with `Commands.guildOnly()`. The definition keeps the
command out of DMs, and `requireGuildId` gives the handler a `string` instead
of `string?`.

`ix.client` exists, but it's typed as just `{ api: Api }` (the interaction
module can't depend on the client module). To reach `client.cache` or other
client methods, use the `client` variable your handler closes over.

### Context menus, selects and autocomplete

| Method | Use it in | Returns |
| --- | --- | --- |
| `ix:targetUser()` | user context menus | `Discord.User?`, the user right-clicked |
| `ix:targetMessage()` | message context menus | `Discord.Message?`, the message right-clicked |
| `ix:values()` | select menus | `{ string }`, the chosen values or IDs |
| `ix:focused()` | autocomplete | `(name?, valueSoFar)` for the option being typed |

The modal readers (`modalValue`, `modalSelected` and the rest) are covered
in [components.md](components.md#reading-a-submission).

### Permissions, precomputed

```luau
local Permissions = Discord.Permissions

if not Permissions.has(ix:appPermissions(), "manageRoles") then
	ix:replyEphemeral("I need the Manage Roles permission here.")
	return
end
```

`ix:appPermissions()` is what the **bot** may do in this channel.
`ix:memberPermissions()` is what the **user** may do. Both are `Bitfield`s
that Discord computed with every role and channel overwrite applied, and
they come with the interaction for free. Prefer them to computing
permissions yourself. `memberPermissions` is empty in DMs. See
[permissions.md](permissions.md).

## When a handler throws

Every handler runs on its own task inside `xpcall`. When one throws:

1. The traceback goes to the log. A REST failure (`ApiError`) is logged as
   its message instead, since Discord's error already says what went wrong.
2. The client emits `error` with `(message, context)`, where `context`
   names the handler, such as `"command /tag get"` or `"component poll:42"`.
   Hook it to forward errors to a log channel or an error tracker. See
   [events.md](events.md#library-events).
3. The user is told something went wrong: an ephemeral reply if the
   interaction wasn't answered yet, or an ephemeral follow-up if it was.
   If the handler had deferred and not filled the placeholder yet, the
   notice replaces the "thinking..." placeholder instead, so it doesn't
   spin forever. That edit keeps the defer's visibility, so after a public
   `defer()` the notice is public too. This is what stops a crash turning
   into "The application did not respond".
4. The shard and every other handler keep running.

The user never sees the error text itself. Discord errors routinely quote
IDs and tokens, and a traceback means nothing to a user anyway.

Autocomplete handlers are the exception to step 3. There's no message to
send in response to a keystroke, so a failed autocomplete just shows no
suggestions.

Set the notice text with the client's `errorMessage` option, or turn it off:

```luau
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
	errorMessage = "That didn't work. The details are in my log.", -- default: "Something went wrong running that."
	-- errorMessage = false, -- send nothing
})
```

Throwing is for bugs. When the user did something wrong, like naming a tag
that doesn't exist, reply with a proper message and `return`. To handle an
API failure yourself, wrap the call in `pcall` and inspect the error with
`Discord.Error.is`. [rest.md](rest.md) shows how.
