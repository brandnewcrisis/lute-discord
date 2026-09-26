# Components

Components are the interactive and layout pieces of a message or a modal:
buttons, select menus, text, images, containers, form fields.
`Discord.Components` builds them.

The constructors return plain tables in Discord's own shape. There's no
builder object to finish. What they add is validation: each one checks
Discord's layout rules and length limits when you call it, and the whole
component tree is checked again before any message is sent. Discord reports
a broken layout rule as `Invalid Form Body` with a JSON path like
`components.0.components.5`. The library reports it as "an action row holds
at most 5 components, got 6", on the line that built it: errors are raised
at the first stack frame outside the library, so they name your line even
when the check runs inside `ix:reply` or `ix:update`.
`Components.validate(components, v2)` runs the whole-message check on its
own, if you build component tables by hand.

Every constructor also checks its spec's keys. Luau accepts an unknown key
in a table literal without complaint, so a misspelled field would otherwise
typecheck, run, and be dropped. The likeliest slip is Discord's own field
name, since that's what the API reference and JSON examples show, so those
are recognised and pointed at the library's: `button has no option
"custom_id"; did you mean "id"?`. The same goes for `min_values` and
`max_values` (`min`, `max`), `min_length` and `max_length` on a text input,
`default_values` (`defaults`), `channel_types` (`channelTypes`), `sku_id`
(`sku`), `accent_color` or `color` on a container (`accent`), and `alt` on
media (`description`). Anything else gets the nearest known key.

```luau
--!strict
local Discord = require("@discord")
local Components = Discord.Components
```

## Buttons

```luau
Components.button({ id = "confirm", label = "Confirm", style = "success" })
Components.button({ id = "delete", label = "Delete", style = "danger", emoji = "\u{1f5d1}\u{fe0f}" })
Components.button({ label = "Documentation", url = "https://example.com/docs" })
Components.linkButton("Documentation", "https://example.com/docs") -- the same thing
```

| Field | Meaning |
| --- | --- |
| `id` | The `custom_id`, 1 to 100 characters. Sent back to you when the button is clicked. |
| `label` | Up to 80 characters. |
| `emoji` | `"\u{1f525}"` (a Unicode emoji), `"name:123456789"` (a custom emoji), or `{ id = ..., name = ..., animated = true }`. |
| `style` | See below. |
| `url` | Link buttons only. |
| `sku` | Premium buttons only: the SKU ID the button sells. |
| `disabled` | Greyed out and unclickable. |

A button needs a label, an emoji, or both. The custom-emoji string form can't
say "animated", so use the table form for animated emoji.

| Style | Looks | Clicking it |
| --- | --- | --- |
| `primary` (default) | blurple | sends your bot an interaction |
| `secondary` | grey | sends your bot an interaction |
| `success` | green | sends your bot an interaction |
| `danger` | red | sends your bot an interaction |
| `link` (default when `url` is set) | grey, with an external-link icon | opens `url` in the browser. Your bot is not told. |
| `premium` (default when `sku` is set) | drawn by Discord from the SKU | opens the purchase flow. Your bot is not told. |

A link button takes a `url` and no `id`. A premium button takes only a `sku`:
no `id`, `label`, `url` or `emoji`, because Discord draws it itself. Every
other button needs an `id`. The constructor refuses any other combination,
which Discord would reject with a bare 400.

## Select menus

There are five kinds. In the first, you supply the options. In the other
four, Discord fills the list itself and sends you the chosen objects already
resolved.

| Constructor | The user picks from |
| --- | --- |
| `Components.select(spec)` | your own `options` |
| `Components.userSelect(spec)` | members of the server |
| `Components.roleSelect(spec)` | roles |
| `Components.mentionableSelect(spec)` | members and roles |
| `Components.channelSelect(spec)` | channels, optionally filtered by `channelTypes` |

```luau
Components.select({
	id = "flavour",
	placeholder = "Choose up to two",
	min = 1,
	max = 2,
	options = {
		{ label = "Vanilla", value = "vanilla", description = "The classic" },
		{ label = "Chocolate", value = "chocolate", default = true },
		{ label = "Strawberry", value = "strawberry" },
	},
})

Components.channelSelect({
	id = "log-channel",
	placeholder = "Where should I post logs?",
	channelTypes = { Discord.ChannelType.GUILD_TEXT },
	defaults = { "123456789012345678" },
})
```

| Field | Meaning |
| --- | --- |
| `id` | The `custom_id`, 1 to 100 characters. |
| `placeholder` | Grey text shown before anything is picked, up to 150 characters. |
| `options` | `select` only: 1 to 25 of `{ label, value, description?, emoji?, default? }`, each text up to 100 characters. |
| `min`, `max` | How many may be picked: `min` 0 to 25, `max` 1 to 25. Both default to 1. |
| `defaults` | The four auto-filled kinds: IDs picked in advance. At most `max` of them, and a non-empty list needs at least `min` (default 1). For a mentionable select, use `{ id = ..., type = "user" }` or `type = "role"`, since an ID alone doesn't say which. |
| `channelTypes` | `channelSelect` only. |
| `disabled` | Greyed out. |
| `required` | Modals only. See [Modals](#modals). |

A string select marks its defaults with `default = true` on an option, not
with `defaults`.

Read the choice with `ix:values()`, which gives you the option values for a
string select and the IDs for the others. For the auto-filled kinds, Discord
also sends the objects themselves, and these return them in the order the
user picked:

| Method | Returns |
| --- | --- |
| `ix:selectedUsers()` | `{ Discord.User }`: users picked in a user or mentionable select |
| `ix:selectedMembers()` | `{ Discord.Member }`: the picked users who are in the server, each with `member.user` filled in |
| `ix:selectedRoles()` | `{ Discord.Role }`: roles picked in a role or mentionable select |
| `ix:selectedChannels()` | `{ Discord.Channel }`: channels picked in a channel select (partial channels) |

A mentionable select's picks are split between `selectedUsers` and
`selectedRoles`. Each returns an empty list when there's nothing of its
kind.

```luau
client:component("pick-user", function(ix: Discord.Interaction)
	local user = ix:selectedUsers()[1]
	ix:update({ content = `You picked {if user then user.username else "nobody"}.`, components = {} })
end)
```

These read a select on a message. In a modal, use `modalUsers` and the other
[modal readers](#reading-a-submission).

## Action rows

In a normal message, every button and select sits in an *action row*, which
is a horizontal line of components. The rules are Discord's:

- A row holds 1 to 5 buttons, or exactly one select menu.
- A message holds at most 5 rows.

`Components.row(...)` builds one row and checks the rule.
`Components.rows(list)` takes a flat list and packs it: buttons five to a row,
and each select on a row of its own.

```luau
local digits = {}
for n = 1, 9 do
	table.insert(digits, Components.button({ id = `digit:{n}`, label = tostring(n), style = "secondary" }))
end

local message: Discord.MessagePayload = {
	content = "Pick a number",
	components = Components.rows(digits), -- two rows: 5 buttons, then 4
}
```

## Handling clicks

`client:component(prefix, handler)` routes a click to the handler whose
prefix matches the start of the `custom_id`:

```luau
client:component("confirm", function(ix: Discord.Interaction)
	ix:update({ content = "Confirmed.", components = {} })
end)
```

In the handler, answer with `ix:update` (edit the message the button is on),
`ix:reply` (send a new message), or `ix:deferUpdate` (acknowledge and change
nothing). A click is an interaction like any other and gets
[three seconds](interactions.md#the-three-second-rule).

### Put the state in the `custom_id`

Buttons stay on a message forever, but your handlers only exist while your
process runs. After a restart, the only thing Discord sends back about a
click is the `custom_id`. That makes the ID the one place to keep state that
has to survive: which poll, which role, which page.

Prefix routing is what makes that work. Encode the data in the ID, register
one handler for the prefix, and parse the rest. This role toggle works across
any number of messages and any number of restarts, and it keeps nothing in
memory:

```luau
--!strict
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components

local client = Discord.Client.new({ token = "...", intents = { "guilds" } })

client:command("rolebutton", function(ix: Discord.Interaction)
	local role = ix:requireRole("role")
	ix:reply({
		content = "Click to toggle the role.",
		components = {
			Components.row(Components.button({ id = `role:{role.id}`, label = role.name })),
		},
	})
end)

client:component("role:", function(ix: Discord.Interaction)
	local roleId = string.match(ix.data.custom_id or "", "^role:(%d+)$")
	local member = ix.member
	local guildId = ix.guildId
	if roleId == nil or member == nil or guildId == nil then
		ix:deferUpdate()
		return
	end
	if table.find(member.roles, roleId) then
		client.api.guilds.removeMemberRole(guildId, ix.user.id, roleId, "role button")
		ix:replyEphemeral(`Removed <@&{roleId}>.`)
	else
		client.api.guilds.addMemberRole(guildId, ix.user.id, roleId, "role button")
		ix:replyEphemeral(`Added <@&{roleId}>.`)
	end
end)

client:deploy({
	Commands.slash("rolebutton", "Post a button that toggles a role")
		:roleOption("role", "Which role", { required = true })
		:defaultPermissions("manageRoles")
		:guildOnly(),
})
client:run()
```

The routing rules:

- **The longest matching prefix wins.** Register `"poll:"` for votes and
  `"poll:close:"` for the close button, and a close click goes to the close
  handler whatever order you registered them in.
- **End prefixes with a delimiter.** `"role"` also matches `"roles-menu"`.
  `"role:"` doesn't.
- **Collectors come first.** A click that an active
  [collector](#collectors) accepts never reaches a prefix route.
- **Unmatched clicks are acknowledged silently.** This is normal after a
  restart, for buttons whose handler was a collector. The click is
  acknowledged so the user's client stops spinning, and it's logged at debug
  level.
- 100 characters is the budget for the whole ID, prefix included.

Clicking tells you who clicked (`ix.user`) and nothing more. If only the
person who posted a poll may close it, put their ID in the button's ID and
compare it with `ix.user.id`.

## Collectors

A prefix route is global and permanent. A collector is local and temporary.
It listens for clicks on one message, from one person, for a limited time,
and it can keep state in local variables because it lives inside the handler
that created it. Use one for a short interactive exchange that doesn't need
to survive a restart.

```luau
client:command("counter", function(ix: Discord.Interaction)
	local count = 0

	local function render(disabled: boolean): Discord.MessagePayload
		return {
			content = `Count: **{count}**`,
			components = {
				Components.row(
					Components.button({ id = "counter:add", label = "+1", disabled = disabled }),
					Components.button({ id = "counter:done", label = "Done", style = "secondary", disabled = disabled })
				),
			},
		}
	end

	ix:reply(render(false))
	local message = ix:fetchReply()

	local collector: Discord.Collector? = nil
	collector = client:collect({
		messageId = message.id, -- only clicks on this message
		userId = ix.user.id, -- only from the person who ran the command
		timeout = 60,
		onCollect = function(click: Discord.Interaction)
			if click.data.custom_id == "counter:done" then
				click:update(render(true))
				if collector then
					collector:stop("done")
				end
			else
				count += 1
				click:update(render(false))
			end
		end,
		onEnd = function(reason: string)
			if reason == "timeout" then
				-- Grey the buttons out, so an expired message doesn't look broken.
				pcall(function()
					ix:editReply(render(true))
				end)
			end
		end,
	})
end)
```

| Option | Meaning |
| --- | --- |
| `messageId` | Only collect from this message. Almost always what you want. |
| `userId` | Only collect from this user. |
| `channelId` | Only collect from this channel. |
| `filter` | `(Discord.Interaction) -> boolean` for any other test. |
| `timeout` | Seconds until the collector ends itself. Default 120. `0` means never. |
| `max` | End after this many collected clicks. |
| `onCollect` | `(Discord.Interaction) -> ()`, called for each click collected, on its own task. |
| `onEnd` | `(reason, collected) -> ()`, called exactly once, however it ended. `reason` is `"timeout"`, `"max"`, `"stopped"`, or whatever you passed to `stop`. |
| `othersMessage` | With both `messageId` and `userId` set, the ephemeral reply to anyone else who clicks. Default `"These buttons aren't for you."`. `false` turns it off. |

The option keys are checked like component specs, so `{ message = id }` or
`{ time = 60 }` fails with the key you meant (`messageId`, `timeout`).

Things to know:

- **You still have to answer.** What `onCollect` receives is an ordinary
  interaction with the usual three seconds. `update`, `reply` or
  `deferUpdate` it. If `onCollect` throws, the error is logged, the user gets
  an ephemeral "Something went wrong handling that." (or, if the click was
  deferred, the placeholder becomes that), and the collector carries on.
- **Scope it with `messageId`.** A collector gets first refusal on every
  component click and modal submission the bot receives, before any prefix
  route. One scoped only by `userId` or `channelId` swallows every click
  within that scope, on every other message too. So a collector created
  with neither `messageId` nor a `filter` logs a warning:
  `collector has no messageId or filter, so it takes every component click
  and modal submit ... and swallows the ones meant for other handlers`. Get
  the ID from `ix:fetchReply()` after replying. A "next click from this
  user, anywhere" collector is legitimate, and a `filter` on the custom ID
  both scopes it and silences the warning.
- **Other people's clicks are answered.** With `messageId` and `userId`
  both set, a click on that message from anyone else gets an ephemeral
  `othersMessage` and goes no further. Without that reply the click would
  fall through to the prefix routes and, with none matching, be acknowledged
  silently, so the button would seem to do nothing. The `filter` still runs
  first, so a click the collector wouldn't have taken anyway isn't turned
  away. Set `othersMessage = false` to let such clicks fall through instead.
- Collectors live in memory. After a restart their buttons fall through to
  prefix routes, or to the silent acknowledgement.
- **`max` is counted as clicks arrive.** A click takes its slot before
  `onCollect` runs, so a double-click can't get two clicks past `max = 1`
  while the first handler is still waiting on Discord. Each `onCollect`
  runs on its own task, and when the last slot is taken the collector ends
  once that handler has finished, so `onEnd` doesn't race the handler's own
  edit.
- `collector:stop(reason?)` ends it early. `collector.collected` holds every
  interaction collected so far.

### `collector:await()`

For a yes/no question, callbacks turn three lines into three functions.
`await` blocks until the first click arrives and returns it, or returns nil
on timeout:

```luau
client:command("reset", function(ix: Discord.Interaction)
	ix:replyEphemeral({
		content = "Reset your settings?",
		components = {
			Components.row(
				Components.button({ id = "reset:yes", label = "Reset", style = "danger" }),
				Components.button({ id = "reset:no", label = "Cancel", style = "secondary" })
			),
		},
	})
	local message = ix:fetchReply()

	local answer = client:collect({ messageId = message.id, timeout = 30, max = 1 }):await()
	if answer == nil then
		ix:editReply({ content = "Timed out. Nothing changed.", components = {} })
	elseif answer.data.custom_id == "reset:yes" then
		answer:update({ content = "Settings reset.", components = {} })
	else
		answer:update({ content = "Cancelled.", components = {} })
	end
end)
```

Blocking is fine here, because every handler runs on its own task. Waiting
in one holds up nothing else. An ephemeral message can only be clicked by
the person who ran the command, so there's no need for `userId`.

## The paginator

`Discord.Paginator.reply` sends a message with first, previous, next and last
buttons and a page counter, and wires them up:

```luau
client:command("roles", function(ix: Discord.Interaction)
	local lines: { string } = {}
	for _, role in client.cache:getRoles(ix:requireGuildId()) do
		table.insert(lines, `<@&{role.id}>, {role.id}`)
	end
	table.sort(lines)

	local pages: { Discord.PaginatorPage } = {}
	for index, chunk in Discord.Paginator.chunk(lines, 15) do
		table.insert(pages, Discord.Embed.new():setTitle(`Roles, page {index}`):setDescription(chunk))
	end
	Discord.Paginator.reply(client, ix, { pages = pages, timeout = 120 })
end)
```

| Option | Meaning |
| --- | --- |
| `pages` | One entry per page: a string (the content), an embed, or a full message payload. |
| `userId` | Who may turn pages. Defaults to whoever ran the command. |
| `timeout` | Seconds before the buttons are disabled. Default 180. |
| `counter` | Show "3 / 10" between the buttons. Default true. |
| `ephemeral` | Send it privately. |

The option keys are checked, as for a collector.

`Paginator.chunk(lines, perPage)` joins a list of lines into page-sized
strings.

It pages by editing the message in place, rather than posting a new message
per page, and it disables the buttons when it times out, so an old
paginator doesn't look broken. It sends the first page with `ix:reply`, so
it works after a `defer`, and after the interaction was already answered:
then the pages go out as a follow-up, and the paginator watches and, on
expiry, edits that follow-up rather than the original response. It returns
the collector, or nil when there's only one page and so nothing to
navigate. Anyone but `userId` who clicks is told, ephemerally, that the
buttons aren't for them (the collector's default `othersMessage`).

A table page is sent as an embed when it has a `toJSON` method (an
`Embed` builder), or has embed fields (`title`, `description`, `fields`,
`image` and so on) and none of a message's (`content`, `embeds`, `embed`,
`components`, `files`). Anything else is a full message payload, and the
navigation row is added after the page's own components.

Every page must be the same kind of message (all Components V2 or none),
because a message can't be switched back from V2. The paginator checks this
up front rather than failing halfway through. Its button IDs start with
`page:`, so don't register a `client:component` prefix that would also match
those, such as `"page"` or `"p"`.

## Components V2

Components V2 is a different kind of message. Instead of `content` plus
embeds plus button rows, the message *is* a layout: text blocks, images,
files, separators and boxed containers, with buttons and selects placed
anywhere among them.

```luau
--!strict
local Discord = require("@discord")
local Components = Discord.Components

local client = Discord.Client.new({ token = "...", intents = { "guilds" } })

client:command("status", function(ix: Discord.Interaction)
	local uptime = math.floor(client:uptime())
	ix:reply({
		components = {
			Components.container(
				{ accent = "#5865F2" },
				Components.section(
					{ accessory = Components.thumbnail(Discord.Api.cdn.userAvatar(ix.user)) },
					"## Status",
					`Up for {uptime} seconds, {math.floor(client:latency() * 1000)} ms to the gateway.`
				),
				Components.separator({ spacing = "large" }),
				"The raw numbers are attached:",
				Components.file("attachment://status.json"),
				Components.row(Components.button({ id = "status:refresh", label = "Refresh", style = "secondary" }))
			),
		},
		files = { { name = "status.json", data = Discord.Json.encode({ uptime = uptime }) } },
	})
end)
```

### The pieces

| Constructor | What it is |
| --- | --- |
| `Components.text(markdown)` | A block of Markdown. The V2 replacement for `content`. Up to 4000 characters, and not empty. |
| `Components.section(spec, ...)` | 1 to 3 texts with an accessory beside them. `spec.accessory` is a button or a thumbnail, and it's required. |
| `Components.thumbnail(url, options?)` | A small image, only valid as a section's accessory. `options`: `description` (alt text), `spoiler`. |
| `Components.gallery(...)` | 1 to 10 images or videos in a grid. Each item is a URL or `{ url, description?, spoiler? }`. |
| `Components.file(url, options?)` | An attached file shown as a download card. The URL must be `attachment://<name>`, naming a file in the same message's `files`. |
| `Components.separator(spec?)` | Vertical space. `divider` (draw a line, default true) and `spacing` (`"small"` or `"large"`). |
| `Components.container(spec, ...)` | A box with an optional coloured bar, the V2 counterpart of an embed. `spec`: `accent` (a number, a `Discord.Color` value, `"#rrggbb"` or `"#rgb"`) and `spoiler`. |

Wherever a text is expected (a section's children, a container's children),
a plain string becomes a text block, so you rarely call `Components.text`
inside a layout.

What goes where:

| In | Allowed |
| --- | --- |
| the top level of a V2 message | rows, texts, sections, galleries, files, separators, containers |
| a container | rows, texts, sections, galleries, files, separators. No container, and no bare button. |
| a section | 1 to 3 texts, plus one accessory |
| a row | buttons, or one select, as in any message |

Images in thumbnails and galleries can be any URL, or `attachment://<name>`
for a file uploaded with the message.

### The `v2` flag, and why it's permanent

A V2 message carries the `IS_COMPONENTS_V2` flag. You can set it with
`v2 = true` in the payload, but usually you don't need to. The library sets
it whenever the top level of `components` includes a V2-only kind (text,
section, gallery, file, separator or container). Without the flag, Discord
refuses those kinds, so setting it can't change the meaning of a message
that would otherwise have worked.

A message with only action rows is valid either way, so it stays a normal
message unless you say `v2 = true`. `v2 = false` means "never": V2 kinds
become an error instead of an upgrade.

The flag is permanent. Once a message is V2, Discord never lets it switch
back, and every later edit is held to V2's rules. That's why the library
won't guess from ambiguous input.

Discord keeps the flag across edits, so an edit (`update`, `editReply`, a
`reply` that fills a deferred placeholder) doesn't have to resend it, or
resend the whole layout. The library can't see the message you're editing,
though, so it checks an edit against the looser V2 limits unless you pass
`v2 = false`, and it can only refuse `content` or `embeds` in an edit if you
say the target is V2. Pass `v2 = true` when you edit a V2 message, and a
mistake is caught before the request goes out.

### What a V2 message can't have

| Not allowed | Use instead |
| --- | --- |
| `content` | `Components.text` |
| `embeds` | `Components.container` |
| `poll` | a normal message |
| stickers | a normal message |

A new V2 message also needs at least one component, since components are all it
shows. The payload check refuses each of these before the request goes out.

Uploaded files work differently too. In a normal message, every upload
appears as an attachment. In a V2 message, a file is only shown when a
component points at it (`Components.file`, a thumbnail, or a gallery item
with `attachment://<name>`). Whenever the library can tell which files the
message will have (the names in `files`, and the `filename` of each entry in
`attachments`), it checks that every `attachment://` reference names one of
them, because Discord reports a dangling reference with a generic error. An
edit keeps the message's existing files unless it lists which to keep, so
the library can only tell on an edit that sends `attachments` with a
`filename` on every entry. Otherwise it skips the check.

### The 40-component budget

A V2 message holds at most **40 components, counting nested ones**. Every
row, every button in it, every text inside a section and every accessory
counts. A container holding a section with two texts and a button accessory,
plus a row with one button, is already 7.

`Components.container` checks its own total when you build it, the payload
check counts the whole message before sending, and
`Components.count(components)` tells you the number yourself. A normal
(non-V2) message has no such total. It has the five-rows rule instead.

## Modals

A modal is a pop-up form. You open one in response to a command or a click,
the user fills it in, and the submission arrives as a new interaction.

```luau
client:command("feedback", function(ix: Discord.Interaction)
	-- No defer: a modal has to be the first response.
	ix:showModal(Components.modal({
		id = "feedback",
		title = "Send feedback",
		components = {
			Components.label(
				"What is it about?",
				Components.radioGroup({
					id = "kind",
					required = true,
					options = {
						{ label = "A bug", value = "bug" },
						{ label = "An idea", value = "idea", default = true },
						{ label = "Something else", value = "other" },
					},
				})
			),
			Components.label("Subject", Components.textInput({ id = "subject", max = 80, required = true })),
			Components.label(
				"Details",
				Components.textInput({ id = "body", style = "paragraph", max = 1000, required = true })
			),
			Components.label(
				"Screenshots",
				Components.fileUpload({ id = "shots", max = 3, required = false }),
				"Optional, up to three"
			),
			Components.label("You may contact me about this", Components.checkbox({ id = "contact" })),
		},
	}))
end)

client:modal("feedback", function(ix: Discord.Interaction)
	local kind = ix:modalValue("kind") or "other"
	local subject = ix:modalValue("subject") or ""
	local shots = ix:modalFiles("shots")
	local contact = ix:modalChecked("contact")
	ix:replyEphemeral(
		`Thanks. Got a {kind} report, "{Discord.Util.escapeMarkdown(subject)}", `
			.. `with {#shots} screenshot(s). Contact: {if contact then "yes" else "no"}.`
	)
end)
```

`Components.modal({ id, title, components })` takes an `id` (the
`custom_id`, 1 to 100 characters), a `title` (up to 45 characters) and 1 to 5
components. `inputs` is accepted as an older name for `components`.

A modal must be the [first response](interactions.md#why-a-modal-cant-follow-a-defer)
to an interaction, so it can't follow a `defer` or a reply. `showModal` throws
if you try.

### Fields

Each field goes inside a **label**, which carries the question text:

```text
Components.label(text, component, description?)
```

`text` is up to 45 characters and `description` (a hint under it) up to 100.
The component can be any of the following:

| Constructor | Collects | Read it with |
| --- | --- | --- |
| `Components.textInput(spec)` | text | `ix:modalValue(id)` |
| `Components.select(spec)` and the four auto-filled selects | picks from a menu | `ix:modalSelected(id)`, or `modalUsers`/`modalRoles`/`modalChannels` |
| `Components.fileUpload(spec)` | uploaded files | `ix:modalFiles(id)` |
| `Components.radioGroup(spec)` | exactly one of 2 to 10 options | `ix:modalValue(id)` |
| `Components.checkboxGroup(spec)` | any number of 1 to 10 options | `ix:modalSelected(id)` |
| `Components.checkbox(spec)` | a single yes/no | `ix:modalChecked(id)` |

A modal may also contain `Components.text(markdown)` blocks between fields,
for instructions.

The specs:

- **`textInput`**: `id`; `style` (`"short"`, the default, or `"paragraph"`
  for multi-line); `placeholder` (up to 100); `value` (pre-filled text, up
  to 4000); `min` (0 to 4000) and `max` (1 to 4000) lengths; `required`.
  Inside a label, don't set the input's own `label`, since the label carries
  the text.
- **Selects**: the same specs as in messages, plus `required`, which
  defaults to true in a modal.
- **`fileUpload`**: `id`; `min` (0 to 10) and `max` (1 to 10) files, both
  defaulting to 1; `required`; `types`, a list like `{ "image", ".pdf" }`.
  `types` is matched on the file extension only, so it's a hint to the file
  picker, not a check. Look at the attachments' `content_type` and `size` if
  it matters.
- **`radioGroup`**: `id`; `options` (2 to 10 of `{ label, value,
  description?, default? }`); `required`.
- **`checkboxGroup`**: `id`; `options` (1 to 10); `min`; `max`; `required`.
- **`checkbox`**: `id`; `default`. A checkbox can't be required, because
  Discord has no such setting for it. To make someone tick a box ("I have
  read the rules"), use a one-option `checkboxGroup` with `required = true`.

`label` checks the rules Discord only applies inside modals: no `disabled`
anywhere, no `label` on a text input inside it, and a `min` of 0 on a select,
file upload or checkbox group only together with `required = false`.
`modal` checks that every non-text field is wrapped in a label and that no
two fields share an ID.

### Legacy text inputs

Before labels existed, a modal held bare text inputs, each carrying its own
`label`. That form is still accepted, and each input goes into its own
action row as Discord expects:

```luau
Components.modal({
	id = "rename",
	title = "Rename",
	components = {
		Components.textInput({ id = "name", label = "New name", max = 32, required = true }),
	},
})
```

Only text inputs work this way. Discord has deprecated the shape, so prefer
labels in new code. You can mix the two in one modal.

### Handling the submission

`client:modal(prefix, handler)` routes submissions by the modal's
`custom_id`, with the same longest-prefix rule as `client:component`. Put
state in the modal's ID exactly as you would with a button:

```luau
client:command("Report user", function(ix: Discord.Interaction)
	local target = ix:targetUser()
	if target == nil then
		ix:replyEphemeral("Discord did not say who that was.")
		return
	end
	ix:showModal(Components.modal({
		id = `report:{target.id}`,
		title = `Report {target.username}`,
		components = {
			Components.label("What happened?", Components.textInput({ id = "reason", style = "paragraph", required = true })),
		},
	}))
end)

client:modal("report:", function(ix: Discord.Interaction)
	local userId = string.match(ix.data.custom_id or "", "^report:(%d+)$")
	local reason = ix:modalValue("reason") or ""
	ix:replyEphemeral(`Thanks. Your report about <@{userId}> was sent to the moderators.`)
	-- ... post `reason` to a moderators' channel
end)
```

A submission is a new interaction with its own three seconds, so it can
`defer` for slow work. It can `reply`, and when the modal was opened from a
button, `update` edits that button's message. It can't open another modal:
Discord doesn't allow a modal in response to a modal submission.

A submission with no matching route gets an ephemeral "That form is no
longer accepting submissions." Collectors get first refusal on submissions,
as they do on clicks.

### Reading a submission

| Method | Returns |
| --- | --- |
| `ix:modalValue(id)` | `string?`: a text input's text, or the chosen value of a radio group. nil when an optional field was left empty. |
| `ix:modalSelected(id)` | `{ string }`: a select's values or IDs, a checkbox group's values, or a file upload's attachment IDs. Empty when nothing was picked. |
| `ix:modalChecked(id)` | `boolean`: whether a checkbox was ticked. |
| `ix:modalFiles(id)` | `{ Discord.Attachment }`: the uploaded files, already resolved. |
| `ix:modalUsers(id)` | `{ Discord.User }`: users picked in a user or mentionable select. |
| `ix:modalRoles(id)` | `{ Discord.Role }`: roles picked in a role or mentionable select. |
| `ix:modalChannels(id)` | `{ Discord.Channel }`: channels picked in a channel select. |
| `ix:modalValues()` | `{ [id]: any }`: every answered field. Strings for text and radio groups, booleans for checkboxes, arrays for selects, checkbox groups and uploads. |

These read both the label form and the legacy form. Prefer the typed readers
to `modalValues`, for the same reason as [`opt`](interactions.md#opt-and-options):
which kind a field is was decided where the modal was built, out of the
checker's sight.

## `setDisabled`

```text
Components.setDisabled(components, true)
```

Walks a component list, however deeply nested (rows, containers, section
accessories), and sets `disabled` on every button and select. Call it when a
poll closes or a collector expires, so the buttons stop pretending to work:

```luau
local message = ix:fetchReply()
ix:editReply({ components = Components.setDisabled(message.components or {}, true) })
```

It modifies the list you pass and returns that same list. If you keep a
components table around to reuse, build a fresh one rather than disabling
the shared copy. For a V2 message, include `v2 = true` in the edit so it's
checked as one (see [above](#the-v2-flag-and-why-its-permanent)).
