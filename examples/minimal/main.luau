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

client:on("ready", function(ready: Discord.Ready)
	print(`logged in as {ready.user.username}`)
end)

client:command("hello", function(ix: Discord.Interaction)
	local name = ix:opt("name", ix.user.global_name or ix.user.username)
	ix:reply({
		content = `Hello, {Discord.Util.escapeMarkdown(name)}!`,
		components = {
			Components.row(Components.button({ id = "wave", label = "Wave back", emoji = "👋" })),
		},
	})
end)

-- Matches any button whose custom_id starts with "wave".
client:component("wave", function(ix: Discord.Interaction)
	ix:replyEphemeral(`{ix.user.username} waved back.`)
end)

client:deploy({
	Commands.slash("hello", "Say hello"):stringOption("name", "Who to greet"),
}, env:get("DISCORD_GUILD_ID"))

client:run()
