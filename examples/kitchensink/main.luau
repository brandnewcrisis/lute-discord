--!strict
--[[
	The kitchen-sink bot: boots the client, registers every feature module,
	publishes the command set, and connects.

	Run it with:

		lute run examples/kitchensink/main.luau

	Flags:

		--deploy-only   publish the commands and exit, without connecting
		--global        publish globally even when DISCORD_GUILD_ID is set

	Commands are published on every start. That is right for an example and
	for development -- the bulk-overwrite route is one request and it deletes
	whatever you removed -- but a large bot should deploy from CI instead, so
	a restart is not a schema change.
]]
local process = require("@lute/process")

local Discord = require("@discord")
local Log = Discord.Log

local Config = require("@bot/config")
local Ctx = require("@bot/ctx")
local Events = require("@bot/events")

local Core = require("@bot/commands/core")
local Info = require("@bot/commands/info")
local Fun = require("@bot/commands/fun")
local Ui = require("@bot/commands/ui")
local Moderation = require("@bot/commands/moderation")
local Utility = require("@bot/commands/utility")

-- `process.args[1]` is the script path; real arguments start at 2.
local flags: { [string]: boolean } = {}
for index = 2, #process.args do
	flags[process.args[index]] = true
end

local config = Config.load()
Log.setLevel(config.logLevel)
Log.setFile(config.logFile)

local FEATURES = { Core, Info, Fun, Ui, Moderation, Utility }

--[[
	Intents: ask for exactly what the handlers use, and no more.

	Over-asking is not free. The three privileged intents have to be enabled
	in the developer portal, and requesting one you were not granted closes
	the socket with 4014 on every attempt -- so they are opt-in here, behind
	PRIVILEGED_INTENTS=1, and the bot runs fine without them with two
	features degraded (welcomes, and prefix commands outside of mentions).
]]
local intents = {
	"guilds",
	"guildMessages",
	"guildMessageReactions",
	"directMessages",
	"directMessageReactions",
	"guildModeration",
	"guildExpressions",
	"guildInvites",
	"guildVoiceStates",
	"guildScheduledEvents",
}
if config.privileged then
	table.insert(intents, "guildMembers")
	table.insert(intents, "messageContent")
end

local client = Discord.Client.new({
	token = config.token,
	intents = intents,
	cache = true,
	logLevel = config.logLevel,
	logFile = config.logFile,
	presence = Discord.Client.presence("watching", "the kitchen sink"),
	errorMessage = "That did not work. The details are in my log.",
})

local ctx: Ctx.Ctx = {
	config = config,
	-- debounce 0 writes through on every set. A busier bot should take
	-- the default and call `store:close()` from its shutdown path.
	store = Discord.Storage.open(`{config.dataDir}/store.json`, { debounce = 0 }),
	commands = {},
}

for _, feature in FEATURES do
	for _, command in feature.commands do
		table.insert(ctx.commands, command)
	end
end
for _, feature in FEATURES do
	feature.register(client, ctx)
end
Events.register(client, ctx)

Log.info(`{#ctx.commands} commands across {#FEATURES} feature modules`)
if not config.privileged then
	Log.info(
		"running without privileged intents: /welcome messages and prefix commands "
			.. "outside of mentions are disabled. Set PRIVILEGED_INTENTS=1 once they are "
			.. "enabled in the developer portal."
	)
end

-- Guild-scoped commands appear instantly; global ones take up to an hour to
-- propagate. Develop against a guild, ship globally.
local target = if flags["--global"] then nil else config.guildId
client:deploy(ctx.commands, target)
if target == nil then
	Log.info("published globally -- allow up to an hour for the client to notice")
end

if flags["--deploy-only"] then
	Log.info("--deploy-only: not connecting")
	return
end

-- Inside `Discord.main` so a fatal close (a bad token, a missing privileged
-- intent) exits with status 1. Lute exits 0 for an error raised after the
-- main thread has yielded, and `run` always has.
Discord.main(function()
	client:run()
end)
