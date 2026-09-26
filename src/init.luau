--!strict
--[[
	lute-discord: a Discord bot library for the Lute Luau runtime.

		local Discord = require("@discord")

		local client = Discord.Client.new({
			token = process.env.DISCORD_TOKEN,
			intents = { "guilds", "guildMessages" },
		})

		client:command("ping", function(ix: Discord.Interaction)
			ix:reply("pong")
		end)

		client:deploy({ Discord.Commands.slash("ping", "Check I am alive") })
		client:run()

	What is covered: the REST API with a real bucket-aware rate limiter, the
	gateway with heartbeats, resume and reconnect, slash commands and context
	menus, buttons, select menus, modals, autocomplete, collectors,
	pagination, permission arithmetic, an event cache, file uploads, a
	crash-durable key-value store, and a cancellable job scheduler.

	What is NOT: voice. Voice needs a UDP socket and an Opus encoder, and
	Lute exposes neither.
]]
local process = require("@lute/process")

local Api = require("@discord/api")
local Bitfield = require("@discord/bitfield")
local Cache = require("@discord/cache")
local Client = require("@discord/client")
local Collector = require("@discord/collector")
local Commands = require("@discord/commands")
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Env = require("@discord/env")
local Error = require("@discord/error")
local Events = require("@discord/events")
local Gateway = require("@discord/gateway")
local Http = require("@discord/http")
local Interaction = require("@discord/interaction")
local Json = require("@discord/json")
local Log = require("@discord/log")
local Paginator = require("@discord/paginator")
local Payload = require("@discord/payload")
local Permissions = require("@discord/permissions")
local Scheduler = require("@discord/scheduler")
local Snowflake = require("@discord/snowflake")
local Storage = require("@discord/storage")
local Types = require("@discord/types")
local Util = require("@discord/util")
local Webhook = require("@discord/webhook")

local Discord = {
	Api = Api,
	Bitfield = Bitfield,
	Cache = Cache,
	Client = Client,
	Collector = Collector,
	Commands = Commands,
	Components = Components,
	Const = Const,
	Embed = Embed,
	Env = Env,
	Error = Error,
	Events = Events,
	Gateway = Gateway,
	Http = Http,
	Interaction = Interaction,
	Json = Json,
	Log = Log,
	Paginator = Paginator,
	Payload = Payload,
	Permissions = Permissions,
	Scheduler = Scheduler,
	Snowflake = Snowflake,
	Storage = Storage,
	Types = Types,
	Util = Util,
	Webhook = Webhook,
}

--[[
	The types a bot annotates things with, re-exported.

	`Discord.Interaction` is a module in value position and this type in type
	position, so one `require("@discord")` covers both -- a handler can say
	`function(ix: Discord.Interaction)` without a second import.

	These are the library's own objects. The shapes Discord itself sends --
	`Message`, `User`, `Guild` and the rest -- live in `@discord/types`,
	which is also reachable here as `Discord.Types`.
]]
export type Client = Client.Client
export type Interaction = Interaction.Interaction
export type Collector = Collector.Collector
export type Command = Commands.Command
export type Handler = Client.Handler
export type Embed = Embed.Embed
export type Env = Env.Env
export type Webhook = Webhook.Webhook
export type Storage = Storage.Storage
export type Scheduler = Scheduler.Scheduler
export type Cache = Cache.Cache
export type Bitfield = Bitfield.Bitfield
export type ApiError = Error.ApiError
export type Api = Api.Api
export type Http = Http.Http
export type Gateway = Gateway.Gateway
export type Snowflake = Types.Snowflake
export type PaginatorPage = Paginator.Page
export type CommandInput = Api.CommandInput

--[[
	The Discord objects a handler meets most, re-exported for the same reason.
	A type path can only be one module deep -- `Discord.Types.Message` is not
	valid Luau -- so without these every feature file would need its own
	`require("@discord/types")` just to annotate a parameter. The long tail
	is still there as `Types.X` for anyone who wants it.
]]
export type User = Types.User
export type Member = Types.Member
export type Role = Types.Role
export type Channel = Types.Channel
export type Guild = Types.Guild
export type Message = Types.Message
export type Emoji = Types.Emoji
export type Attachment = Types.Attachment
export type Component = Types.Component
export type ActionRow = Types.ActionRow
export type Modal = Types.Modal
export type MessagePayload = Types.MessagePayload
export type MessageInput = Types.MessageInput
export type AllowedMentions = Types.AllowedMentions
export type File = Types.File
export type Presence = Types.Presence
export type Ready = Types.Ready
export type GuildMemberEvent = Types.GuildMemberEvent
export type MessageReactionAdd = Types.MessageReactionAdd
export type MessageReactionRemove = Types.MessageReactionRemove
export type MessageDelete = Types.MessageDelete

Discord.VERSION = Const.VERSION

--[[
	Runs a script's body and, if it throws, prints the error and exits 1.

		Discord.main(function()
			local api = Discord.Api.new(Discord.Http.new(token))
			api.channels.createMessage(channelId, "hello")
		end)

	Worth using for any script that calls the API outside a client handler.
	REST failures throw an `ApiError` object, and Lute's top level prints
	nothing for an uncaught table -- a 401 from a stale token would show up
	as a stack trace with no message. This prints the message.
]]
function Discord.main(fn: () -> ())
	local ok, err = xpcall(function(): boolean
		fn()
		return true
	end, function(problem: unknown): string
		-- `tostring` runs the ApiError's `__tostring`, which is the part
		-- Lute's own top level would have dropped.
		return debug.traceback(tostring(problem), 2)
	end)
	if not ok then
		Log.error(tostring(err))
		process.exit(1)
	end
end

-- The handful of constants worth having at the top level.
Discord.Color = Discord.Const.Color
Discord.ChannelType = Discord.Const.ChannelType

return Discord
