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

## 2. Create the project

The library isn't in a package registry. You install it by putting a copy of
the repository inside your project. A git submodule is the simplest way to
do that, and it pins the exact version you tested against. Then the
scaffold writes the rest of the project for you:

```bash
mkdir my-bot && cd my-bot
git init
git submodule add https://github.com/brandnewcrisis/lute-discord.git vendor/lute-discord
cd vendor/lute-discord
rokit install
lute run tools/new.luau ../..
cd ../..
```

The scaffold runs from inside the library because that's where a toolchain
manifest already exists: rokit only runs tools listed in a manifest it can
find, and your project doesn't have one until the scaffold writes it.
`rokit install` fetches the pinned Lute the first time. The `../..` is the
path back to your project. If you have Lute on your `PATH` some other way,
`lute run vendor/lute-discord/tools/new.luau .` from the project root does
the same.

It lists what it wrote:

```text
project: /home/you/my-bot
library: ./vendor/lute-discord/src
  wrote   rokit.toml
  wrote   .luaurc
  wrote   .gitignore
  wrote   .env.example
  wrote   main.luau
  wrote   commands/init.luau
  wrote   commands/ping.luau
```

| File | What it's for |
| --- | --- |
| `rokit.toml` | Pins Lute 1.0.0, the version the library is tested against. |
| `.luaurc` | Strict mode, a `discord` alias pointing at the library's `src/`, and a `bot` alias for your project root. |
| `.gitignore` | Keeps `.env`, `*.log` and `data/` out of git. |
| `.env.example` | The variables the bot reads, with a comment on each. |
| `main.luau` | Creates the client, registers the commands, publishes them, and connects. |
| `commands/init.luau` | The list of every command the bot has. |
| `commands/ping.luau` | One command, `/ping`. |

It never overwrites a file. One that already exists is listed as `kept` and
left alone, so running it in a half-set-up project fills in only what's
missing.

Now install the pinned toolchain:

```bash
rokit install
```

The `discord` alias is computed from where the library sits, so it's right
even if you put the submodule somewhere other than `vendor/`. Whatever the
path, the alias must be named `discord`: the library's own modules require
each other as `@discord/...`, so any other name breaks those requires.

Two things to know about submodules. Anyone who clones your bot needs
`git clone --recurse-submodules` (or `git submodule update --init` after a
plain clone), otherwise `vendor/lute-discord` is empty. And you upgrade on
purpose, with `git submodule update --remote vendor/lute-discord`, then commit
the new pointer.

### Setting up by hand

The scaffold only writes files, so you can do the same yourself. Create
`.luaurc` in your project root:

```json
{ "languageMode": "strict", "aliases": { "discord": "./vendor/lute-discord/src", "bot": "." } }
```

and a `rokit.toml` next to it, then run `rokit install`:

```toml
[tools]
lute = "luau-lang/lute@1.0.0"
```

rokit needs this file even though the library ships one of its own. For the
bot itself, `examples/minimal/main.luau` in the library is a complete bot in
one file, and the steps below explain each piece of it.

## 3. Keep the token out of your code

Copy the example environment file and fill it in:

```bash
cp .env.example .env
```

```bash
DISCORD_TOKEN=paste-the-token-here
DISCORD_GUILD_ID=your-test-server-id
```

The scaffold's `.gitignore` already keeps `.env` out of git. (Set up by
hand? Run `echo ".env" >> .gitignore` before you create it.)

`Discord.Env.load()` reads this file. Real environment variables win over
it, so the same code runs on your laptop with a `.env` and in production with
secrets injected as variables.

To get the server ID, turn on **Developer Mode** (Discord **User Settings >
Advanced**), then right-click your server's icon and pick **Copy Server ID**.
Developer Mode also adds **Copy ID** to users, channels and messages, which
you'll want constantly.

## 4. Read the bot

This is the `main.luau` the scaffold wrote:

```luau
--!strict
-- Starts the bot: lute run main.luau
local Discord = require("@discord")

local commands = require("@bot/commands")

local env = Discord.Env.load()

local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	-- Slash commands and buttons arrive whatever intents you ask for; add
	-- more (e.g. "guildMessages") when you listen for gateway events.
	intents = { "guilds" },
	logLevel = env:get("LOG_LEVEL", "info"),
	-- Shows the error text to the user when a handler throws. Handy while
	-- developing; turn it off before inviting the bot anywhere real.
	showErrors = true,
})

client:on("ready", function(ready)
	print(`logged in as {ready.user.username}`)
end)

client:register(commands)
-- With DISCORD_GUILD_ID set, commands go to that server only, instantly.
client:deploy(nil, env:get("DISCORD_GUILD_ID"))

-- Inside Discord.main so a bad token or a missing intent exits with a
-- non-zero status and a readable message.
Discord.main(function()
	client:run()
end)
```

Piece by piece:

- `require("@discord")` gives you one table holding every module
  (`Discord.Commands`, `Discord.Components`, `Discord.Embed` and so on). It
  also works as a type namespace: `Discord.Interaction`, `Discord.Message`
  and the other common types come with it, so you rarely need a second
  require. `@bot/commands` is your own `commands/init.luau`.
- `env:require` throws with the variable's name if it's missing or empty,
  which beats a confusing 401 from Discord later.
- `intents` says which gateway events Discord should send you. Slash
  commands and button clicks arrive whatever you ask for, so `guilds` is
  plenty here. [events.md](events.md#intents) covers the rest.
- `showErrors = true` puts the first line of an error in the message the
  user sees when a handler throws, so you see what broke without reading
  the log. Turn it off before the bot is anywhere public
  ([interactions.md](interactions.md#when-a-handler-throws) says why).
  `Client.new` checks its option names, so a misspelled one
  (`showError`) fails with the name you meant instead of being ignored.
- `client:on("ready", ...)` runs once the bot is connected. The listener's
  parameter is typed from the event name, so `ready` is a `Discord.Ready`
  without an annotation.
- `client:register(commands)` routes the handlers attached to each command.
  `client:deploy` uploads the command definitions to Discord, which is what
  makes them appear in the `/` menu. With no list it publishes everything
  registered. The second argument is a server ID, which makes the commands
  appear in that server straight away (see below). After deploying, it
  warns about any command without a handler, and any handler without a
  command.
- `client:run` connects and blocks for as long as the bot runs. If the bot
  can't stay connected (a wrong token, say), it raises an error with the
  reason, and `Discord.main` logs it and exits with status 1.
  [deploying.md](deploying.md#clientrun-and-clientlogin) covers running
  unattended.

The command itself is in `commands/ping.luau`:

```luau
--!strict
local Discord = require("@discord")

return Discord.Commands.slash("ping", "Check the bot is alive"):handle(function(ix: Discord.Interaction)
	ix:reply("pong")
end)
```

`Commands.slash` defines the command, and `:handle` attaches the function
that answers it, so the definition and its handler live together. `ix` is
the [interaction](interactions.md): one user running one command.
`ix:reply` answers. `commands/init.luau` lists every command file, and
`main.luau` registers that list.

## 5. Add a command

Add a `/hello` command with a button. Create `commands/hello.luau`:

```luau
--!strict
local Discord = require("@discord")
local Components = Discord.Components

return Discord.Commands.slash("hello", "Say hello")
	:stringOption("name", "Who to greet")
	:handle(function(ix)
		local name = ix:getString("name") or ix.user.global_name or ix.user.username
		ix:reply({
			content = `Hello, {Discord.Util.escapeMarkdown(name)}!`,
			components = {
				Components.row(Components.button({ id = "wave", label = "Wave back", emoji = "\u{1f44b}" })),
			},
		})
	end)
```

`ix:getString("name")` reads the option, or returns nil when the user left
it out. It also checks that `name` really is a string option, so the
definition and the handler can't quietly disagree. `ix:reply` answers, and
here it attaches a button. `escapeMarkdown` stops a name like `**x**` from
turning bold.

Add it to the list in `commands/init.luau`:

```luau
local commands: { Discord.Command } = {
	require("@bot/commands/ping"),
	require("@bot/commands/hello"),
}
```

Then handle the button in `main.luau`, before `client:deploy`:

```luau
client:component("wave", function(ix)
	ix:replyEphemeral(`{ix.user.username} waved back.`)
end)
```

A button carries a `custom_id` (the `id` you gave it), and `client:component`
routes by prefix of that id. `replyEphemeral` sends a reply that only the
person who clicked can see.

## 6. Run it

```bash
lute check main.luau commands/*.luau   # optional: typecheck first
lute run main.luau
```

The log should look roughly like this:

```text
2026-09-26 12:00:01 INFO	deployed 2 command(s) to guild 123456789012345678
2026-09-26 12:00:01 INFO	gateway: 1 shard(s), 999/1000 session starts left, max concurrency 1
2026-09-26 12:00:01 INFO	shard 0: identifying
2026-09-26 12:00:02 INFO	[MyBot] shard 0: ready as MyBot in 1 guild(s)
logged in as MyBot
```

In Discord, type `/hello` in your test server, press Enter, then click
**Wave back**. Stop the bot with Ctrl+C.

If it doesn't work, the log says why:

| You see | Cause |
| --- | --- |
| `DISCORD_TOKEN is not set in ...` | The `.env` file is missing, not in the directory you ran from, or the line is empty. |
| `Discord 401 ...` and `the bot token is invalid or has been reset` | The token is wrong, or you reset it after copying. Copy a fresh one. |
| `/hello is deployed but has no handler` | The builder in `commands/hello.luau` has no `:handle`. |
| `/hello` doesn't appear | `commands/hello.luau` isn't in the list in `commands/init.luau`, the bot was invited without `applications.commands`, or `DISCORD_GUILD_ID` is unset and you're waiting on a global deploy. Discord's client also caches the command list: press Ctrl+R to reload it. |
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
