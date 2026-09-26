# Commands

A command has two halves:

- The **definition**: name, description, options. You build it with
  `Discord.Commands` and upload it with `client:deploy`. Discord stores it
  and draws the `/` menu from it.
- The **handler**: the function that runs when someone uses the command.
  It never leaves your process.

Discord never sees your handler, and your handler never sees the
definition. Two things follow from that split, and they explain most of
this page.

First, Discord checks a definition strictly, but only when you deploy it,
and it rejects the whole batch over one bad name. So the builders check
Discord's rules as you call them, and a mistake fails on your line with a
message that names the rule instead of an `Invalid Form Body` from the API.

Second, the two halves drift. Rename an option in the definition and a
handler in another file keeps reading the old name. So a handler can live
on the builder itself, with `:handle`, and after every deploy the client
warns about any published command with no handler and any handler with no
published command.

```luau
--!strict
local Discord = require("@discord")
local Commands = Discord.Commands

local client = Discord.Client.new({ token = "...", intents = { "guilds" } })

local roll = Commands.slash("roll", "Roll a die")
	:integerOption("sides", "How many sides", { min = 2, max = 100 })
	:handle(function(ix)
		local sides = ix:getInteger("sides") or 6
		ix:reply(`You rolled {math.random(1, sides)}.`)
	end)

client:register(roll) -- routes the handler
client:deploy() -- publishes everything registered
```

## Slash commands

`Commands.slash(name, description)` starts a `/name` command and returns a
builder. Every builder method returns the builder, so calls chain.

| Field | Rule | Checked by the builder |
| --- | --- | --- |
| name | 1 to 32 characters: lowercase letters, digits, `-`, `_` and `'` | yes |
| description | 1 to 100 characters | yes |

The name rule is stricter than it needs to be for display because the name
is also what users type. Discord also allows lowercase letters from other
scripts. Luau's patterns only know ASCII, so the builder refuses ASCII
capitals and passes any non-ASCII name through for Discord to check.

## Options

Options are the arguments a user fills in after the command name. Add them
with the shorthand methods, each taking `(name, description, extra?)`:

| Method | The user enters | Read it with |
| --- | --- | --- |
| `stringOption` | text | `ix:getString`, `ix:requireString` |
| `integerOption` | a whole number | `ix:getInteger`, `ix:requireInteger` |
| `numberOption` | a number, decimals allowed | `ix:getNumber`, `ix:requireNumber` |
| `booleanOption` | True or False | `ix:getBoolean`, `ix:requireBoolean` |
| `userOption` | a user, from a picker | `ix:getUser`, `ix:getMember`, `ix:requireUser`, `ix:requireMember` |
| `channelOption` | a channel | `ix:getChannel`, `ix:requireChannel` |
| `roleOption` | a role | `ix:getRole`, `ix:requireRole` |
| `mentionableOption` | a user or a role | `ix:getMentionable`, `ix:requireMentionable` |
| `attachmentOption` | an uploaded file | `ix:getAttachment`, `ix:requireAttachment` |

```luau
Commands.slash("tip", "Tip someone")
	:mentionableOption("who", "A user or a role", { required = true })
	:numberOption("amount", "How much", { required = true, min = 0.01 })
```

A `mentionable` option's value is an ID that could be a user or a role.
`ix:getMentionable(name)` works out which, and returns a record whose `kind`
is `"user"` or `"role"`. See
[interactions.md](interactions.md#mentionables).

The shorthands wrap the general `option` method, which takes the same
fields as one table, plus a `type`: one of `"string"`, `"integer"`,
`"number"`, `"boolean"`, `"user"`, `"channel"`, `"role"`, `"mentionable"` or
`"attachment"`. This is the `amount` option above, written out:

```luau
Commands.slash("tip", "Tip someone")
	:option({ name = "amount", description = "How much", type = "number", required = true, min = 0.01 })
```

[interactions.md](interactions.md#reading-options) covers reading options in
detail, including why the typed getters check the option's type and why
`require*` exists.

### Extra settings

The `extra` table (or the same fields in an `option` spec) accepts:

| Field | Applies to | Meaning |
| --- | --- | --- |
| `required` | all | The user can't send the command without it. |
| `choices` | string, integer, number | A fixed list to pick from. At most 25. |
| `autocomplete` | string, integer, number | Ask your bot for suggestions as the user types. See [Autocomplete](#autocomplete). |
| `min`, `max` | integer, number | Smallest and largest value allowed. |
| `minLength`, `maxLength` | string | Shortest and longest text allowed (0 to 6000). |
| `channelTypes` | channel | Which kinds of channel to offer, as `Discord.ChannelType` values. |
| `nameLocalizations`, `descriptionLocalizations` | all | Translated option name and description, keyed by locale. See [Localization](#localization). |

The builder checks the "applies to" column: a setting on the wrong type of
option is an error. The likeliest one, `min` or `max` on a string option
meant as its length, comes with a hint to use `minLength` and `maxLength`,
because Discord would otherwise ignore it without a word.

Discord enforces all of these in its client, before your handler runs. A
`max = 100` option never arrives as 101, so you don't need to re-check it.

```luau
Commands.slash("remind", "Set a reminder")
	:stringOption("what", "What to remind you about", { required = true, maxLength = 200 })
	:integerOption("minutes", "In how many minutes", { required = true, min = 1, max = 1440 })
	:channelOption("where", "Where to post it", { channelTypes = { Discord.ChannelType.GUILD_TEXT } })
```

### Choices

Choices turn an option into a dropdown. The user sees `name`, and your
handler receives `value`, which lets you rename what users see without
touching the handler:

```luau
Commands.slash("coffee", "Order a coffee")
	:stringOption("size", "Cup size", {
		required = true,
		choices = {
			{ name = "Small (8 oz)", value = "small" },
			{ name = "Large (16 oz)", value = "large" },
		},
	})
```

A choice can also carry `name_localizations`, a map from locale to
translated name (see [Localization](#localization)).

### What the builder checks

These mistakes throw when you call the builder, not when you deploy:

- A name or description that breaks the rules above.
- A misspelled key in an option spec or an `extra` table. Luau accepts an
  unknown key in a table literal without complaint, so `{ min_value = 2 }`
  would typecheck, run, and do nothing. The error names the key you
  probably meant: `option "sides" has no option "min_value"; did you mean
  "min"?`. Discord's own field names (`min_value`, `max_length`,
  `channel_types` and the rest), which are what the API reference and most
  JSON examples show, are recognised and pointed at the builder's names.
- An unknown option `type`.
- A setting on a type it doesn't apply to (see the table above), such as
  `min` on a string or `channelTypes` on a role option.
- A required option added after an optional one. Discord requires every
  required option to come first. Otherwise, when the user has typed two
  values, it can't tell which option the second one belongs to.
- Two options with the same name at one level.
- More than 25 options on one command or subcommand.
- More than 25 choices, or `choices` together with `autocomplete`.
- Plain options mixed with subcommands or groups at the same level (see
  [below](#subcommands-and-groups)).
- A group nested inside a group.
- A handler on a group (see [Handlers](#handlers)).
- An unknown permission name in `defaultPermissions`, with the likely
  intended name.

The error is raised at the first stack frame outside the library, so it
names the line in your bot that made the mistake, not a line in
`commands.luau`.

## Autocomplete

Choices top out at 25 and have to be known when you deploy. Autocomplete
lifts both limits. Discord asks your bot for suggestions on each keystroke,
and you answer with up to 25 of them.

Mark the option with `autocomplete = true`, then give the command an
autocomplete handler with `:onAutocomplete`:

```luau
--!strict
local Discord = require("@discord")
local Types = require("@discord/types")
local Commands = Discord.Commands

local client = Discord.Client.new({ token = "...", intents = { "guilds" } })

local CITIES = { "Amsterdam", "Berlin", "Lisbon", "London", "Paris", "Prague" }

local weather = Commands.slash("weather", "Look up a city")
	:stringOption("city", "Start typing", { required = true, autocomplete = true })
	:onAutocomplete(function(ix)
		local _, typed = ix:focused()
		local needle = string.lower(tostring(typed or ""))
		local choices: { Types.AutocompleteChoice } = {}
		for _, city in CITIES do
			if string.find(string.lower(city), needle, 1, true) then
				table.insert(choices, { name = city, value = city })
			end
		end
		ix:autocomplete(choices)
	end)
	:handle(function(ix)
		local city = ix:requireString("city")
		if not table.find(CITIES, city) then
			return ix:replyEphemeral("I don't know that city.")
		end
		ix:reply(`It is always sunny in {city}.`)
	end)

client:register(weather)
client:deploy()
```

`client:autocomplete(path, handler, commandType?)` does the same without a
builder, the way `client:command` does for command handlers (see
[Routing](#routing)).

Things to know:

- `ix:focused()` returns the name of the option being typed and its value so
  far. When a command has several autocomplete options, one handler can
  branch on the name. On a numeric option the value so far is the raw text;
  `ix:getInteger` and `ix:getNumber` parse it, and return nil while it isn't
  a number yet (`""`, `"-"`).
- `ix:autocomplete(choices)` sends the list. Anything past 25 is dropped.
- Suggestions aren't a constraint. The user can ignore them and submit any
  text, so validate the value in the command handler, as the example does.
- Autocomplete has the same three-second deadline as everything else, but
  the user is watching each keystroke. Answer from memory. A remote API call
  per keystroke is the usual reason autocomplete "stops working" under load.
- If there's no handler for the command, the library answers with an empty
  list so the user's client doesn't spin forever.
- Autocomplete routes the same way as commands (see [Routing](#routing)): the
  full subcommand path first, then the bare command name.

## Subcommands and groups

Subcommands split one command into several actions (`/tag get`, `/tag set`),
which keeps the `/` menu short and groups related options together.

```luau
Commands.slash("tag", "Saved snippets")
	:subcommand("get", "Show a tag", function(sub)
		sub:stringOption("name", "Which tag", { required = true, autocomplete = true })
	end)
	:subcommand("set", "Create or replace a tag", function(sub)
		sub:stringOption("name", "Tag name", { required = true })
		sub:stringOption("content", "What it says", { required = true })
	end)
	:subcommand("list", "Every tag on this server")
```

`subcommand(name, description, build?)` hands `build` a fresh builder, on
which you add the subcommand's own options and its handler (see
[Handlers](#handlers)). Leave `build` out when there's nothing to add.

A group adds one more level (`/config roles add`):

```luau
Commands.slash("config", "Server settings")
	:group("roles", "Self-assignable roles", function(roles)
		roles:subcommand("add", "Make a role self-assignable", function(sub)
			sub:roleOption("role", "Which role", { required = true })
		end)
		roles:subcommand("remove", "Stop offering a role", function(sub)
			sub:roleOption("role", "Which role", { required = true })
		end)
	end)
	:subcommand("show", "Show the current settings")
```

Discord's nesting rules:

- A command holds subcommands, groups, or both. A group holds subcommands.
  A group can't hold a group, and the builder refuses one.
- A command with subcommands can't also have plain options at the same
  level, and it can't be run on its own: `/tag` by itself isn't a command
  the user can send. The builder refuses the mix.

## Context menus

Context-menu commands appear when a user right-clicks (or long-presses) a
user or a message, under **Apps**.

```luau
Commands.userCommand("Show avatar")
Commands.messageCommand("Quote this")
```

They take no description (Discord rejects one) and no options. Their names
are shown exactly as written, so, unlike slash commands, they may contain
capitals and spaces, up to 32 characters.

The handler reads the target from the interaction:

```luau
--!strict
local Discord = require("@discord")
local Commands = Discord.Commands
local client = Discord.Client.new({ token = "...", intents = { "guilds" } })

local avatar = Commands.userCommand("Show avatar"):handle(function(ix)
	local user = ix:targetUser()
	if user == nil then
		return ix:replyEphemeral("Discord did not say who that was.")
	end
	ix:replyEphemeral(Discord.Api.cdn.userAvatar(user, { size = 512 }))
end)

local quote = Commands.messageCommand("Quote this"):handle(function(ix)
	local message = ix:targetMessage()
	if message == nil then
		return ix:replyEphemeral("Discord did not send the message.")
	end
	ix:reply({
		content = `<@{message.author.id}> said:\n>>> {message.content}`,
		-- Quoting someone shouldn't ping them.
		allowed_mentions = Discord.Payload.NO_MENTIONS,
	})
end)

client:register(avatar, quote)
```

Discord includes the target message's content even without the Message
Content intent: the user chose to show it to your bot.

Handlers are kept per command type, so a slash command `info` and a user
command `info` can each have their own. See [Routing](#routing).

## Command settings

### `defaultPermissions(...)`

```luau
Commands.slash("purge", "Delete recent messages")
	:integerOption("count", "How many", { required = true, min = 1, max = 100 })
	:defaultPermissions("manageMessages")
	:guildOnly()
```

Hides the command from members who lack all of the listed permissions.
Names are the camelCase keys of `Discord.Const.PermissionBits`
(`"kickMembers"`, `"manageGuild"`, `"moderateMembers"`). Called with no
names, it hides the command from everyone except administrators.

This is a default, not a lock. Server admins can override it per role and
per channel under **Server Settings > Integrations**, and Discord then shows
the command to whoever they choose. If a command must not run without a
permission, check at invoke time as well:

```luau
Commands.slash("purge", "Delete recent messages")
	:integerOption("count", "How many", { required = true, min = 1, max = 100 })
	:defaultPermissions("manageMessages")
	:guildOnly()
	:handle(function(ix)
		if not Discord.Permissions.has(ix:memberPermissions(), "manageMessages") then
			return ix:replyEphemeral("You need Manage Messages for that.")
		end
		-- ...
	end)
```

`ix:memberPermissions()` is computed by Discord for the channel the command
was used in. [permissions.md](permissions.md) covers the arithmetic.

### `guildOnly(value?)`

Restricts the command to servers, so it doesn't appear in DMs. Set it on
anything that reads members, roles or channels. Without it, the command
shows up in DMs, where `ix.guildId` is nil and the handler fails in a way
the user can't understand. `guildOnly(false)` explicitly allows servers and
DMs with the bot. Group DMs and other people's DMs only exist for
user-installed apps, so they come with `userInstallable()` instead.

It works by setting the command's `contexts` (`{ 0 }`, or `{ 0, 1 }` for
`guildOnly(false)`). Pair it with `ix:requireGuildId()` in the handler,
which gives you a non-optional `string` for the type checker.

### `userInstallable()`

Makes the command available when a user installs the app to their own
account, not only when a server adds it. The command then works in any
server, DM or group DM that user is in, including ones the bot hasn't
joined. It sets `integration_types` to `{ 0, 1 }` and `contexts` to
`{ 0, 1, 2 }`, so call it instead of `guildOnly`, not as well.

The application also needs **User Install** enabled under **Installation**
in the developer portal. Where the bot isn't a member, the interaction has
no guild object, the cache knows nothing, and only the interaction token can
answer, so reply to the interaction rather than calling channel routes.

### `nsfw(value?)`

Marks the command age-restricted. Discord only offers it in age-restricted
channels, and only to users who have verified their age.

### Localization

```luau
Commands.slash("hello", "Say hello")
	:localize({ fr = "bonjour", ["es-ES"] = "hola" }, { fr = "Dire bonjour", ["es-ES"] = "Saludar" })
```

`localize(names?, descriptions?)` sets the translated names and descriptions
Discord shows to users whose client is in that language. Keys are Discord
locale codes (`fr`, `de`, `es-ES`, `pt-BR`, `ja` and so on). Each call
replaces both maps. Your handler still routes on the base name: `/bonjour`
arrives as `hello`.

`localize` covers the command (or subcommand) it's called on. Options take
`nameLocalizations` and `descriptionLocalizations` in their `extra` table:

```luau
Commands.slash("hello", "Say hello")
	:userOption("who", "Who to greet", {
		nameLocalizations = { fr = "qui" },
		descriptionLocalizations = { fr = "Qui saluer" },
	})
```

## Handlers

### `handle` and `onAutocomplete`

`:handle(fn)` attaches the function that answers a command. Called on the
builder a `subcommand` callback receives, it attaches that subcommand's:

```luau
local tag = Commands.slash("tag", "Saved snippets")
	:subcommand("get", "Show a tag", function(sub)
		sub:stringOption("name", "Which tag", { required = true, autocomplete = true })
		sub:handle(function(ix)
			ix:reply(`You asked for {ix:requireString("name")}.`)
		end)
		sub:onAutocomplete(function(ix)
			ix:autocomplete({ { name = "rules", value = "rules" } })
		end)
	end)
	:subcommand("list", "Every tag on this server", function(sub)
		sub:handle(function(ix)
			ix:reply("No tags yet.")
		end)
	end)
```

- `:onAutocomplete(fn)` attaches the autocomplete handler for the command or
  subcommand. It runs for every option marked `autocomplete = true`, and
  `ix:focused()` says which one the user is typing in.
- A command with subcommands may have a `:handle` of its own too. It
  answers any subcommand that has no handler.
- A group can't take a handler. Discord only ever invokes the subcommands
  inside a group, never the group, so a handler there could never run, and
  the builder says so: `group "roles" cannot have a handler; put one on each
  of its subcommands`.
- A handler is a `Discord.Handler`: `(Discord.Interaction) -> ...any`. The
  return value is ignored. It's `...any` so that `return ix:reply(...)`
  typechecks, which makes an early exit one line.

### `client:register`

A handler on a builder does nothing until the client knows about it.
`client:register` walks each builder, files every handler under its full
path and command type, and remembers the builders, so `client:deploy()`
with no list publishes exactly what was registered. It takes the builders as
arguments, or as one list:

```luau
client:register(ping, tag, weather) -- builders as arguments
client:register(commands) -- one list, typically from a module
```

Prefer the argument form when you write builders inline. Luau 1.0.0 doesn't
carry the expected type into a function nested inside a table literal, so
this fails to typecheck:

```luau
client:register({
	Commands.slash("ping", "Check I am alive"):handle(function(ix)
		ix:reply("pong") -- error: `ix` isn't inferred inside a table literal
	end),
})
```

The same builder passed as an argument infers `ix` as a
`Discord.Interaction`. Inside a table literal, annotate every function
parameter yourself: `function(ix: Discord.Interaction)`, and
`function(sub: Discord.Command)` for a `subcommand` callback.

A list assembled in a module is fine, because each handler is written as an
argument to `:handle` in its own file and only the finished builder goes in
the list:

```luau
--!strict
-- commands/init.luau
local Discord = require("@discord")

local commands: { Discord.Command } = {
	require("@bot/commands/ping"),
	require("@bot/commands/tag"),
}

return commands
```

A few more rules:

- `register` returns the builders it registered, as a list.
- Registering the same builder twice is harmless: handlers are keyed by
  path, and a builder already remembered isn't added again.
- It only takes builders. A plain command table carries no handler, so
  `register` rejects one. Publish those with `client:deploy(list)` and route
  them with `client:command`.
- `Commands.handlers(command)` returns what `register` reads: a list of
  `{ path, type, run?, autocomplete? }`, one per handler on the builder and
  its subcommands. It's there for a bot with its own router.

## Routing

`client:command(path, handler, commandType?)` registers a handler without a
builder, and returns the client. `register` goes through the same routing.

For a plain command the path is its name. For subcommands it's the full path,
space-separated, exactly as the user sees it:

```luau
client:command("tag get", function(ix: Discord.Interaction) end)
client:command("tag set", function(ix: Discord.Interaction) end)
client:command("config roles add", function(ix: Discord.Interaction) end)
```

Routing tries the full path first, then falls back to the bare command name.
So you can handle every subcommand in one place (with a builder, that's a
`:handle` on the command itself):

```luau
client:command("tag", function(ix: Discord.Interaction)
	local path = ix:commandPath() -- "tag get", "tag set" or "tag list"
	if path == "tag list" then
		ix:reply("No tags yet.")
	else
		ix:replyEphemeral(`{path} is not written yet.`)
	end
end)
```

and mix the two: a specific path wins over the bare name, so `"tag get"` can
have its own handler while `"tag"` catches the rest.

### Command types

Handlers are kept per command type, so a slash command `/info` and a user
context menu called "info" don't collide. `register` always knows the type
from the builder. `client:command` without a `commandType` answers its path
for every type that has no handler of its own. Pass one to scope it:

```luau
client:command("info", function(ix: Discord.Interaction)
	ix:replyEphemeral(`That is {(ix:targetUser() or ix.user).username}.`)
end, Discord.Const.CommandType.USER)
```

The order routing tries, most specific first: a handler for this type and
the full path, an untyped one for the full path, then the same two for the
bare command name. The bare-name step is for slash commands only, since a
context menu's name is one unit, spaces and all.

### Other rules

- Registering the same path (and type) twice replaces the first handler.
- If nothing matches, the library logs a warning and replies ephemerally
  with ``/path` is not wired up on this bot.``, so the user doesn't see "The
  application did not respond". The post-deploy check (see
  [below](#handler-and-command-mismatches)) usually tells you before a user
  does.
- Every handler runs on its own task, so a slow handler doesn't hold up the
  others. If it throws, the error is contained and reported; see
  [interactions.md](interactions.md#when-a-handler-throws).

## Deploying

```text
client:deploy(commands: { Command | ApplicationCommand }?, guildId: string?) -> { ApplicationCommand }
```

`deploy` uploads commands and returns what Discord stored (a list of
`Types.ApplicationCommand` from `@discord/types`, with the IDs Discord
assigned).

- **With no list** (`client:deploy()`, or `client:deploy(nil, guildId)`), it
  publishes every builder given to `client:register`. Calling it before
  anything was registered is an error.
- **With a list**, it publishes that list as given and ignores what was
  registered. The list can hold builders or plain tables in Discord's own
  shape.
- **With a `guildId`**, the commands go to that one server and appear
  instantly. Use this while developing.
- **Without one**, they're global: every server the bot is in, plus DMs.
  Discord's clients pick up global changes over time, and it can take up to
  an hour.

Global and guild commands are separate lists, and a user in your test server
sees both. When you go global, clear the guild list with
`client:deploy({}, guildId)` or every command shows up twice.

### Handler and command mismatches

After each deploy, the client compares what it published with the handlers
it has, and logs a warning for each mismatch:

```text
WARN	/role remove is deployed but has no handler; users will see "not wired up"
WARN	handler for /pign is registered but no such command was deployed; typo? (did you mean /ping?)
```

Both are silent otherwise until a user tries the command. The second is
nearly always a typo, and its real command then shows up as the first.
Autocomplete handlers are checked the same way. Each mismatch is reported
once per client. A handler counts as matched by any deploy so far, so a bot
that publishes some commands to a guild and the rest globally isn't told
its guild handlers are orphans by the global deploy.

The check knows the handlers from `register`, `client:command` and
`client:autocomplete`. Builders passed straight to `deploy(list)` count
too: `deploy` registers the handlers they carry before publishing.

### Bulk overwrite, and why it's the only deploy you need

`deploy` uses Discord's bulk-overwrite route: the list you pass becomes the
complete set. Commands in the list are created or updated, and commands
missing from it are deleted. It's one request whatever the size of the set.

Compare that with creating commands one at a time. Deleting a command from
your code wouldn't delete it from Discord, so stale commands would linger in
the `/` menu. Each create is also its own request against a rate limit, and
Discord caps how many new commands an application can create per day. With
bulk overwrite, your code is the source of truth, and running the same deploy
twice changes nothing. Commands whose name and type are unchanged keep their
IDs, and any permission overrides server admins set on them.

`deploy` works before the client connects. It looks up the application ID
over REST if it doesn't know it yet. A failure is raised as a plain string
with Discord's message, plus a hint when the cause is a bad token, because
Lute prints nothing useful for an uncaught error object at the top level.

The returned IDs let you mention a command as a clickable link:

```luau
for _, command in client:deploy() do
	if command.name == "help" then
		print(`</{command.name}:{command.id}>`) -- paste into a message to get a clickable /help
	end
end
```

### Deploying from CI

Deploying on every start, as the examples do, is fine while you develop.
For a bot that's running for real, deploy as a separate step:

- A restart shouldn't be a schema change. You want to publish commands when
  you release, not whenever the process happens to restart.
- A crash loop would otherwise hit the deploy route on every restart.
- A global deploy takes time to spread, so you want to do it once, on
  purpose.

Keep the commands in their own module, as the `commands/init.luau` above
does, so the bot and the deploy script share them. The deploy script
registers them too, even though it never runs a handler: that's what lets
the mismatch check see the handlers and stay quiet.

```luau
--!strict
-- deploy.luau: `lute run deploy.luau` publishes the commands and exits.
local Discord = require("@discord")
local commands = require("@bot/commands")

local env = Discord.Env.load()
local client = Discord.Client.new({ token = env:require("DISCORD_TOKEN"), intents = {} })

client:register(commands)
-- Guild when DISCORD_GUILD_ID is set, global otherwise.
client:deploy(nil, env:get("DISCORD_GUILD_ID"))
```

`deploy` only talks to the REST API, so the script never opens a gateway
connection and doesn't interfere with a running bot. `intents` is required
by `Client.new` but unused here. Run it from your pipeline with the token
supplied as a secret environment variable. An error ends the script with a
non-zero exit code, which fails the job.

The bot itself then calls `client:register(commands)` and `client:run()`,
and no `deploy`. The mismatch check runs after a deploy, so it happens in
the deploy script's output, not the bot's.
[deploying.md](deploying.md#deploying-commands-from-ci) shows this step in a
pipeline alongside the rest of a release.
