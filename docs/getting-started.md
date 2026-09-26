# Getting started

This page takes you from nothing to a bot that answers a slash command and a
button click. It takes about fifteen minutes, most of it in Discord's
developer portal.

You need:

- [rokit](https://github.com/rojo-rbx/rokit), which installs the pinned Lute
  toolchain (Lute 1.0.0). Any Lute 1.0.0 on your `PATH` works too.
- `git`.
- A Discord server where you have the **Manage Server** permission, so you
  can add the bot to it. Make a private one for testing; it's free.

## 1. Create the application

Everything Discord knows about your bot lives in an *application* in the
[developer portal](https://discord.com/developers/applications).

1. Click **New Application**, give it a name, and accept the terms. The name
   is what users see on the bot's profile. You can change it later.
2. On **General Information**, note the **Application ID**. You need it for
   the invite link below.
3. Open the **Bot** page. Every new application already has a bot user. This
   is the account your code logs in as.
4. Click **Reset Token**, confirm, and copy the token. Discord shows it once.
   Anyone who has it can log in as your bot, so treat it like a password:
   keep it out of git, out of screenshots and out of chat. If it leaks,
   reset it here and the old one stops working at once.
5. Leave the three **Privileged Gateway Intents** switched off for now. The
   first bot doesn't need them, and [events.md](events.md#intents) explains
   when you do.

### Invite the bot to your server

A bot joins a server through an OAuth2 link that a server admin opens. Build
one with **OAuth2 > URL Generator**: tick the `bot` and
`applications.commands` scopes, then tick the permissions your bot needs
(**Send Messages** is enough for this page). Or write it by hand:

```text
https://discord.com/oauth2/authorize?client_id=YOUR_APPLICATION_ID&scope=bot%20applications.commands&permissions=2048
```

The two scopes do different jobs. `bot` adds the bot user to the server.
`applications.commands` lets the application register slash commands there.
Without it the bot joins, but its commands never show up. `permissions` is a
decimal bitmask (2048 is Send Messages). The admin can untick any of them on
the consent screen, so your code should never assume it got them all. See
[permissions.md](permissions.md).

Open the link, pick your test server, and authorise. The bot appears in the
member list, offline until your code logs in.

## 2. Install lute-discord

The library isn't in a package registry. You install it by putting a copy of
the repository inside your project, then pointing a `.luaurc` alias at its
`src/` folder. A git submodule is the simplest way to do that, and it pins
the exact version you tested against:

```bash
mkdir my-bot && cd my-bot
git init
git submodule add https://github.com/brandnewcrisis/lute-discord.git vendor/lute-discord
```

Create `.luaurc` in your project root:

```json
{ "languageMode": "strict", "aliases": { "discord": "./vendor/lute-discord/src" } }
```

The alias must be named `discord`. The library's own modules require each
other as `@discord/...`, so any other name breaks those requires.

Pin the toolchain with a `rokit.toml` of your own, next to `.luaurc`:

```toml
[tools]
lute = "luau-lang/lute@1.0.0"
```

Then install it:

```bash
rokit install
```

rokit only runs tools listed in a manifest it can find, so this file is
needed even though the library ships one of its own.

Two things to know about submodules. Anyone who clones your bot needs
`git clone --recurse-submodules` (or `git submodule update --init` after a
plain clone), otherwise `vendor/lute-discord` is empty. And you upgrade on
purpose, with `git submodule update --remote vendor/lute-discord`, then commit
the new pointer.

## 3. Keep the token out of your code

Create a `.env` file in the project root:

```bash
DISCORD_TOKEN=paste-the-token-here
DISCORD_GUILD_ID=your-test-server-id
```

and make sure git never sees it:

```bash
echo ".env" >> .gitignore
```

`Discord.Env.load()` reads this file. Real environment variables win over
it, so the same code runs on your laptop with a `.env` and in production with
secrets injected as variables.

To get the server ID, turn on **Developer Mode** (Discord **User Settings >
Advanced**), then right-click your server's icon and pick **Copy Server ID**.
Developer Mode also adds **Copy ID** to users, channels and messages, which
you'll want constantly.

## 4. Write the bot

This is `examples/minimal/main.luau` from the library, built up one piece at a
time. Put the pieces in `main.luau` in your project root.

Start with strict mode, the library, and the configuration:

```luau
--!strict
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components

local env = Discord.Env.load()
```

`require("@discord")` gives you one table holding every module
(`Discord.Commands`, `Discord.Components`, `Discord.Embed` and so on). It
also works as a type namespace: `Discord.Interaction`, `Discord.Message` and
the other common types come with it, so you rarely need a second require.

Create the client:

```luau
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
})
```

`env:require` throws with the variable's name if it's missing or empty, which
beats a confusing 401 from Discord later. `intents` says which gateway events
Discord should send you. Slash commands and button clicks arrive whatever you
ask for, so `guilds` is plenty here. [events.md](events.md#intents) covers the
rest.

Listen for the moment the bot is connected:

```luau
client:on("ready", function(ready: Discord.Ready)
	print(`logged in as {ready.user.username}`)
end)
```

Handle a slash command:

```luau
client:command("hello", function(ix: Discord.Interaction)
	local name = ix:opt("name", ix.user.global_name or ix.user.username)
	ix:reply({
		content = `Hello, {Discord.Util.escapeMarkdown(name)}!`,
		components = {
			Components.row(Components.button({ id = "wave", label = "Wave back", emoji = "\u{1f44b}" })),
		},
	})
end)
```

`ix` is the [interaction](interactions.md): one user running one command.
`ix:opt("name", default)` reads an option, falling back to the default when
the user didn't fill it in. `ix:reply` answers, and here it attaches a button.
`escapeMarkdown` stops a name like `**x**` from turning bold.

Handle the button:

```luau
client:component("wave", function(ix: Discord.Interaction)
	ix:replyEphemeral(`{ix.user.username} waved back.`)
end)
```

A button carries a `custom_id` (the `id` you gave it), and `client:component`
routes by prefix of that id. `replyEphemeral` sends a reply that only the
person who clicked can see.

Publish the command and connect:

```luau
client:deploy({
	Commands.slash("hello", "Say hello"):stringOption("name", "Who to greet"),
}, env:get("DISCORD_GUILD_ID"))

client:run()
```

Registering a handler with `client:command` doesn't tell Discord the command
exists. `client:deploy` does that: it uploads the command definitions. The
second argument is a server ID, which makes the command appear in that server
straight away (see below). `client:run` connects and blocks for as long as
the bot runs. If the bot can't stay connected (a wrong token, say), it
raises an error with the reason. [deploying.md](deploying.md#clientrun-and-clientlogin)
covers handling that when the bot runs unattended.

Here is the whole file:

```luau
--!strict
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components

local env = Discord.Env.load()

local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
})

client:on("ready", function(ready: Discord.Ready)
	print(`logged in as {ready.user.username}`)
end)

client:command("hello", function(ix: Discord.Interaction)
	local name = ix:opt("name", ix.user.global_name or ix.user.username)
	ix:reply({
		content = `Hello, {Discord.Util.escapeMarkdown(name)}!`,
		components = {
			Components.row(Components.button({ id = "wave", label = "Wave back", emoji = "\u{1f44b}" })),
		},
	})
end)

client:component("wave", function(ix: Discord.Interaction)
	ix:replyEphemeral(`{ix.user.username} waved back.`)
end)

client:deploy({
	Commands.slash("hello", "Say hello"):stringOption("name", "Who to greet"),
}, env:get("DISCORD_GUILD_ID"))

client:run()
```

## 5. Run it

```bash
lute check main.luau   # optional: typecheck first
lute run main.luau
```

The log should look roughly like this:

```text
12:00:01 INFO   deployed 1 command(s) to guild 123456789012345678
12:00:01 INFO   gateway: 1 shard(s), 999/1000 session starts left, max concurrency 1
12:00:01 INFO   shard 0: identifying
12:00:02 INFO   [MyBot] shard 0: ready as MyBot in 1 guild(s)
logged in as MyBot
```

In Discord, type `/hello` in your test server, press Enter, then click
**Wave back**. Stop the bot with Ctrl+C.

If it doesn't work, the log says why:

| You see | Cause |
| --- | --- |
| `DISCORD_TOKEN is not set in ...` | The `.env` file is missing, not in the directory you ran from, or the line is empty. |
| `Discord 401 ...` and `the bot token is invalid or has been reset` | The token is wrong, or you reset it after copying. Copy a fresh one. |
| `/hello` doesn't appear | The bot was invited without `applications.commands`, or `DISCORD_GUILD_ID` is unset and you're waiting on a global deploy. Discord's client also caches the command list: press Ctrl+R to reload it. |
| "The application did not respond" | The bot isn't running, or a handler took longer than three seconds. See [interactions.md](interactions.md#the-three-second-rule). |

[troubleshooting.md](troubleshooting.md) has the full list.

## Guild commands and global commands

Commands can be registered in two places:

- **In one server (guild).** They appear immediately, and only there. Use
  this while you develop, which is why the example passes `DISCORD_GUILD_ID`.
- **Globally.** They appear in every server the bot is in, and in DMs. Discord
  distributes them to its clients over time, and it can take up to an hour.

It's the same call either way. Leave out the guild ID (or set
`DISCORD_GUILD_ID` to nothing) and the deploy is global.

One trap when you switch: guild and global commands are separate lists. A
command you deployed to your test server stays there after you deploy the
same command globally, and users of that server see it twice. Clear the guild
list by deploying an empty one to it:

```luau
client:deploy({}, "123456789012345678")
```

## Where to go next

- [commands.md](commands.md): options, choices, autocomplete, subcommands,
  context menus, and deploying.
- [interactions.md](interactions.md): replying, deferring for slow work,
  ephemeral messages, and reading options safely.
- [components.md](components.md): buttons, select menus, collectors,
  pagination, Components V2 layouts, and modals.
- [events.md](events.md): reacting to messages, members and reactions, and
  which intents each event needs.
- `examples/kitchensink/` in the library: a working bot with 36 commands
  that uses nearly every feature. Reading its `commands/` folder is the
  fastest way to see idiomatic code.
