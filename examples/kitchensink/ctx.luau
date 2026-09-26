--!strict
--[[
	What every feature module is handed.

	It lives in its own file rather than in `main.luau` because `main` is the
	one module that requires all the others -- a feature reaching back into
	it for the type would be a cycle. This is the shared vocabulary of the
	bot: parsed configuration, the durable store, and the command list that
	`/help` renders from.
]]
local Discord = require("@discord")

local Config = require("@bot/config")

local Ctx = {}

export type Ctx = {
	config: Config.Config,
	store: Discord.Storage,
	--- Every command across every feature module, in deploy order. `/help`
	--- reads this, so it can never drift from what was actually published.
	commands: { Discord.Command },
}

return Ctx
