--!strict
--[[
	The smallest useful bot: one slash command, one button, one event.

		lute run examples/minimal/main.luau

	Needs DISCORD_TOKEN in the environment or in `.env`. Set DISCORD_GUILD_ID
	too while developing, so the command appears instantly instead of within
	the hour a global publish can take.
]]
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components

local env = Discord.Env.load()

local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	-- `guilds` is enough for slash commands and buttons: interactions arrive
	-- whatever intents you ask for.
	intents = { "guilds" },
})

-- Listener parameters are typed from the event name: `ready` is a Ready.
client:on("ready", function(ready)
	print(`logged in as {ready.user.username}`)
end)

-- The command's schema and its handler live together, so renaming an
-- option can't leave the handler reading one that no longer exists.
client:register(Commands.slash("hello", "Say hello")
	:stringOption("name", "Who to greet")
	:handle(function(ix)
		local name = ix:getString("name") or ix.user.global_name or ix.user.username
		ix:reply({
			content = `Hello, {Discord.Util.escapeMarkdown(name)}!`,
			components = {
				Components.row(Components.button({ id = "wave", label = "Wave back", emoji = "👋" })),
			},
		})
	end))

-- Matches any button whose custom_id starts with "wave".
client:component("wave", function(ix)
	ix:replyEphemeral(`{ix.user.username} waved back.`)
end)

-- Publishes everything registered above.
client:deploy(nil, env:get("DISCORD_GUILD_ID"))

-- Inside Discord.main so a bad token or a missing intent exits non-zero.
Discord.main(function()
	client:run()
end)
