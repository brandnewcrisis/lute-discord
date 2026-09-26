--!strict
--[[
	Configuration, read from the environment with a `.env` fallback.

	`Discord.Env` does the parsing, and real environment variables win over
	the file -- which is what makes the same checkout work in a container
	that injects secrets and has no `.env` at all.
]]
local Discord = require("@discord")

local Config = {}

export type Config = {
	token: string,
	guildId: string?,
	logLevel: string,
	logFile: string?,
	dataDir: string,
	--- Ask for the privileged intents. Off by default: they must be enabled
	--- in the developer portal first, and a bot that asks for one it was not
	--- granted cannot connect at all.
	privileged: boolean,
	prefix: string,
}

function Config.load(): Config
	local env = Discord.Env.load()
	local token = env:get("DISCORD_TOKEN")
	if token == nil then
		error(
			"DISCORD_TOKEN is not set. Copy .env.example to .env and paste your bot token, "
				.. "or export DISCORD_TOKEN before running.",
			0
		)
	end

	return {
		token = token,
		guildId = env:get("DISCORD_GUILD_ID"),
		logLevel = env:get("LOG_LEVEL", "info") :: string,
		logFile = env:get("LOG_FILE"),
		dataDir = env:get("DATA_DIR", "./examples/kitchensink/data") :: string,
		privileged = env:flag("PRIVILEGED_INTENTS"),
		prefix = env:get("PREFIX", "!") :: string,
	}
end

return Config
