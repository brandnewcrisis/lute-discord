--!strict
--[[
	Typed events and the listener diagnostics.

	Half of this file is a TYPE test: the listeners below leave their
	parameters unannotated and pass them through `known`, which fails to
	typecheck when a parameter comes out as `any` or `unknown`. If the
	`Events.On` overloads stop being picked, every handler silently becomes
	`(any) -> ()` -- which runs fine -- and `lute run tools/check.luau` is
	what notices. The other half checks the runtime warnings for misspelled
	event names and missing intents, captured through `Log.setHook`.
]]
local task = require("@lute/task")

local Client = require("@discord/client")
local Events = require("@discord/events")
local Log = require("@discord/log")
local Types = require("@discord/types")
local h = require("./harness")

----------------------------------------------------------------------------
-- Type test
----------------------------------------------------------------------------

--- Errors at check time when `T` is `any` or `unknown`.
type function Known(t)
	if t.tag == "any" or t.tag == "unknown" then
		error(`a listener parameter was inferred as {t.tag}; the typed event overloads are not being picked`)
	end
	return t
end

-- A generic call is what forces `Known` to see the solved type; used
-- directly as an annotation it runs before the lambda's parameter is known.
local function known<T>(value: T): Known<T>
	return value :: any
end

local typed = Client.new({ token = "TOKEN", intents = 0, logLevel = "error" })

typed:on("messageCreate", function(m)
	known(m)
	local _content: string? = m.content
	local _author: string = m.author.id
end)
typed:once("guildMemberAdd", function(member)
	known(member)
	local _guild: string = member.guild_id
end)
typed:on("messageReactionAdd", function(reaction)
	known(reaction)
	local _emoji: string? = reaction.emoji.name
end)
typed:on("ready", function(ready)
	known(ready)
	local _session: string = ready.session_id
end)
typed:on("shardDisconnect", function(shardId, code)
	known(shardId)
	local _id: number = shardId
	local _code: number? = code
end)
typed:on("error", function(message, context)
	known(message)
	local _text: string = message
	local _context: string = context
end)
typed:on("interactionCreate", function(raw)
	known(raw)
	local _token: string = raw.token
end)
-- An annotated parameter of the right type still fits, and a listener may
-- take fewer parameters than the event passes. Annotating is also the way
-- around the operator limitation described on `Events.On`.
typed:on("guildCreate", function(guild: Types.Guild)
	local _name: string = "joined " .. guild.name
end)
typed:on("messageDelete", function() end)
-- Any other name falls through to the untyped overload.
typed:on("myOwnEvent", function(a: any, b: any)
	local _ = { a, b }
end)
-- Listeners and handlers may return a value; it is ignored.
typed:on("messageCreate", function(m)
	return m.id
end)
typed:command("typed-return", function(ix)
	return ix:reply("x")
end)
typed:component("typed:", function(ix)
	return ix:deferUpdate()
end)

-- waitFor's filter parameters are inferred too.
task.spawn(function()
	local reply: Types.Message? = typed:waitFor("messageCreate", function(m): boolean
		known(m)
		return m.content == "yes"
	end, 0)
	local _ = reply
end)

----------------------------------------------------------------------------
-- The registry and `Handlers` name the same events
----------------------------------------------------------------------------

-- Typed as the `Handlers` keys, so a name here that `Handlers` lacks fails
-- to typecheck; the count pin below catches one `Handlers` has and this
-- list lacks; the loop catches the registry disagreeing with either.
local NAMES: { keyof<Events.Handlers> } = {
	"ready",
	"shardReady",
	"shardResume",
	"shardDisconnect",
	"error",
	"raw",
	"resumed",
	"userUpdate",
	"interactionCreate",
	"applicationCommandPermissionsUpdate",
	"entitlementCreate",
	"entitlementUpdate",
	"entitlementDelete",
	"subscriptionCreate",
	"subscriptionUpdate",
	"subscriptionDelete",
	"guildMembersChunk",
	"soundboardSounds",
	"voiceServerUpdate",
	"rateLimited",
	"guildCreate",
	"guildUpdate",
	"guildDelete",
	"guildRoleCreate",
	"guildRoleUpdate",
	"guildRoleDelete",
	"channelCreate",
	"channelUpdate",
	"channelDelete",
	"channelPinsUpdate",
	"threadCreate",
	"threadUpdate",
	"threadDelete",
	"threadListSync",
	"threadMemberUpdate",
	"threadMembersUpdate",
	"stageInstanceCreate",
	"stageInstanceUpdate",
	"stageInstanceDelete",
	"voiceChannelStatusUpdate",
	"voiceChannelStartTimeUpdate",
	"guildMemberAdd",
	"guildMemberUpdate",
	"guildMemberRemove",
	"guildAuditLogEntryCreate",
	"guildBanAdd",
	"guildBanRemove",
	"guildEmojisUpdate",
	"guildStickersUpdate",
	"guildSoundboardSoundCreate",
	"guildSoundboardSoundUpdate",
	"guildSoundboardSoundDelete",
	"guildSoundboardSoundsUpdate",
	"guildIntegrationsUpdate",
	"integrationCreate",
	"integrationUpdate",
	"integrationDelete",
	"webhooksUpdate",
	"inviteCreate",
	"inviteDelete",
	"voiceChannelEffectSend",
	"voiceStateUpdate",
	"presenceUpdate",
	"messageCreate",
	"messageUpdate",
	"messageDelete",
	"messageDeleteBulk",
	"messageReactionAdd",
	"messageReactionRemove",
	"messageReactionRemoveAll",
	"messageReactionRemoveEmoji",
	"typingStart",
	"guildScheduledEventCreate",
	"guildScheduledEventUpdate",
	"guildScheduledEventDelete",
	"guildScheduledEventUserAdd",
	"guildScheduledEventUserRemove",
	"autoModerationRuleCreate",
	"autoModerationRuleUpdate",
	"autoModerationRuleDelete",
	"autoModerationActionExecution",
	"messagePollVoteAdd",
	"messagePollVoteRemove",
}

type function Count(t)
	local n = 0
	for _ in t:properties() do
		n += 1
	end
	return types.singleton(tostring(n))
end
local HANDLER_COUNT: Count<Events.Handlers> = "83"

do
	local registered = 0
	for _ in Events.REGISTRY do
		registered += 1
	end
	local missing = {}
	for _, name in NAMES do
		if Events.REGISTRY[name] == nil then
			table.insert(missing, name)
		end
	end
	h.equals("every typed event is in the registry", table.concat(missing, ", "), "")
	h.equals("and the registry has no others", registered, #NAMES)
	h.equals("and Handlers has no others", tonumber(HANDLER_COUNT), #NAMES)
	for name, entry in Events.REGISTRY do
		for _, intent in entry.intents do
			if (require("@discord/const").IntentBits :: { [string]: number })[intent] == nil then
				h.check(`{name} names a real intent ({intent})`, false)
			end
		end
	end
end

----------------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------------

type Line = { level: string, message: string }
local lines: { Line } = {}
Log.setHook(function(level: string, message: string)
	table.insert(lines, { level = level, message = message })
end)

--- Lines logged while `fn` runs, at info and above, off stdout.
local function capture(fn: () -> ()): { Line }
	lines = {}
	Log.setLevel("info")
	fn()
	Log.setLevel("error")
	return lines
end

local function count(found: { Line }, level: string, fragment: string): number
	local n = 0
	for _, line in found do
		if line.level == level and string.find(line.message, fragment, 1, true) ~= nil then
			n += 1
		end
	end
	return n
end

local function client(intents: { string } | number): Client.Client
	return Client.new({ token = "TOKEN", intents = intents, logLevel = "error" })
end

-- Misspelled names.
do
	local c = client({ "guilds", "guildMessages", "guildMembers" })
	local found = capture(function()
		c:on("messagecreate", function() end)
		c:on("messagecreate", function() end)
		c:once("guildMemberAd", function() end)
		c:waitFor("guildCreat", nil, 0)
		c:on("somethingElseEntirely", function() end)
	end)
	h.equals(
		"a misspelled event name warns with the right spelling",
		count(found, "warn", 'no event named "messagecreate"; did you mean "messageCreate"?'),
		1
	)
	h.equals("once per name", count(found, "warn", '"messagecreate"'), 1)
	h.equals("once() checks too", count(found, "warn", 'did you mean "guildMemberAdd"?'), 1)
	h.equals("waitFor() checks too", count(found, "warn", 'did you mean "guildCreate"?'), 1)
	h.equals("a custom name still warns, without a guess", count(found, "warn", 'no event named "somethingElseEntirely" ('), 1)
	h.check("and says emit is fine", count(found, "warn", "client:emit") >= 1)

	local quiet = capture(function()
		for _, name in { "ready", "shardReady", "shardResume", "shardDisconnect", "resumed", "error", "raw" } do
			c:on(name, function() end)
		end
		c:on("interactionCreate", function() end)
		c:on("guildCreate", function() end)
		c:on("userUpdate", function() end)
	end)
	h.equals("library events and delivered events log nothing", #quiet, 0)
end

-- Missing intents.
do
	local c = client({ "guilds" })
	local found = capture(function()
		c:on("guildMemberAdd", function() end)
		c:on("guildMemberAdd", function() end)
		c:on("messageCreate", function() end)
		c:on("guildBanAdd", function() end)
		c:once("presenceUpdate", function() end)
	end)
	h.equals(
		"a listener with its intent off warns, naming the intent",
		count(found, "warn", 'listening for "guildMemberAdd", but the guildMembers intent is not enabled, so it will never fire'),
		1
	)
	h.equals("once per event", count(found, "warn", '"guildMemberAdd"'), 1)
	h.equals("a privileged intent says the portal switch is needed too", count(found, "warn", "guildMembers is privileged"), 1)
	h.equals(
		"an event with several intents names them all",
		count(found, "warn", "none of the intents that deliver it (guildMessages, directMessages) is enabled"),
		1
	)
	h.check(
		"a non-privileged intent does not mention the portal",
		count(found, "warn", "guildModeration intent is not enabled") == 1 and count(found, "warn", "guildModeration is privileged") == 0
	)
	h.equals("once() checks intents too", count(found, "warn", "guildPresences is privileged"), 1)
	h.equals("threadMembersUpdate arrives with guilds alone", #capture(function()
		c:on("threadMembersUpdate", function() end)
	end), 0)
end

-- messageContent, and intents given as a raw mask.
do
	local dmOnly = capture(function()
		client({ "directMessages" }):on("messageCreate", function() end)
	end)
	h.equals("either delivering intent is enough (no warning)", count(dmOnly, "warn", "messageCreate"), 0)

	local c = client(2 ^ 9) -- guildMessages, as a number
	local found = capture(function()
		c:on("messageCreate", function() end)
		c:on("messageUpdate", function() end)
		c:on("messageCreate", function() end)
		c:on("guildMemberAdd", function() end)
	end)
	h.equals("a raw mask is read bit by bit (guildMessages is on)", count(found, "warn", '"messageCreate"'), 0)
	h.equals("and bits it lacks still warn", count(found, "warn", "guildMembers intent is not enabled"), 1)
	h.equals(
		"without messageContent, one info line per message event",
		count(found, "info", 'listening for "messageCreate" without the messageContent intent'),
		1
	)
	h.check("saying content is empty outside DMs and mentions", count(found, "info", "except in DMs and messages that mention the bot") == 2)

	local withContent = capture(function()
		client(2 ^ 9 + 2 ^ 15):on("messageCreate", function() end)
	end)
	h.equals("with messageContent there is nothing to say", #withContent, 0)
end

Log.setHook(nil)
h.finish()
