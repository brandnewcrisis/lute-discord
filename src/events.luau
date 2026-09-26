--!strict
--[[
	Every event `client:on` knows: the intents that make Discord send it,
	and the payload its listener receives.

	Two jobs hang off this module.

	  * Types. `On` and `WaitFor` tie an event name to its payload, so
	    `client:on("messageCreate", function(m) ... end)` infers `m` as a
	    `Message` with no annotation, and a listener annotated with the
	    wrong payload type fails to typecheck.
	  * Diagnostics. A listener for an event none of whose intents are
	    enabled never fires, and nothing says so -- the most common "my
	    handler does nothing" report there is. The client checks each new
	    listener against `REGISTRY`, names the missing intent, and suggests
	    the right spelling for a name that is not here at all.

	The intent lists are Discord's "List of Intents" (gateway docs). An
	event with several intents is delivered by ANY of them: `messageCreate`
	arrives with `guildMessages` for servers and `directMessages` for DMs.
	An empty list means Discord sends it whatever the intents.

	Adding an event means a line in `REGISTRY` and one in `Handlers`;
	`tests/events.test.luau` fails if the two disagree.
]]
local Const = require("@discord/const")
local Spec = require("@discord/spec")
local Types = require("@discord/types")

local Events = {}

--- A payload with no fields worth naming (RESUMED).
export type Loose = { [string]: any }

export type Entry = {
	--- Any one of these delivers the event. Empty: always delivered.
	intents: { string },
	--- The payload's type in `@discord/types`, or the argument list for
	--- the library's own multi-argument events.
	payload: string,
	--- Raised by the client rather than sent by Discord.
	library: boolean?,
}

Events.REGISTRY = table.freeze({
	-- Library events: raised by the client itself, not sent by Discord
	ready = { intents = {}, payload = "Ready", library = true },
	shardReady = { intents = {}, payload = "(shardId, resumed)", library = true },
	shardResume = { intents = {}, payload = "(shardId)", library = true },
	shardDisconnect = { intents = {}, payload = "(shardId, closeCode?)", library = true },
	error = { intents = {}, payload = "(message, context)", library = true },
	raw = { intents = {}, payload = "(eventName, data)", library = true },
	-- Connection and application (no intent needed)
	resumed = { intents = {}, payload = "Loose" },
	userUpdate = { intents = {}, payload = "User" },
	interactionCreate = { intents = {}, payload = "Interaction" },
	applicationCommandPermissionsUpdate = { intents = {}, payload = "GuildApplicationCommandPermissions" },
	entitlementCreate = { intents = {}, payload = "Entitlement" },
	entitlementUpdate = { intents = {}, payload = "Entitlement" },
	entitlementDelete = { intents = {}, payload = "Entitlement" },
	subscriptionCreate = { intents = {}, payload = "Subscription" },
	subscriptionUpdate = { intents = {}, payload = "Subscription" },
	subscriptionDelete = { intents = {}, payload = "Subscription" },
	guildMembersChunk = { intents = {}, payload = "GuildMembersChunk" },
	soundboardSounds = { intents = {}, payload = "GuildSoundboardSounds" },
	voiceServerUpdate = { intents = {}, payload = "VoiceServerUpdate" },
	rateLimited = { intents = {}, payload = "RateLimited" },
	-- guilds
	guildCreate = { intents = { "guilds" }, payload = "Guild" },
	guildUpdate = { intents = { "guilds" }, payload = "Guild" },
	guildDelete = { intents = { "guilds" }, payload = "UnavailableGuild" },
	guildRoleCreate = { intents = { "guilds" }, payload = "GuildRoleEvent" },
	guildRoleUpdate = { intents = { "guilds" }, payload = "GuildRoleEvent" },
	guildRoleDelete = { intents = { "guilds" }, payload = "GuildRoleDelete" },
	channelCreate = { intents = { "guilds" }, payload = "Channel" },
	channelUpdate = { intents = { "guilds" }, payload = "Channel" },
	channelDelete = { intents = { "guilds" }, payload = "Channel" },
	channelPinsUpdate = { intents = { "guilds", "directMessages" }, payload = "ChannelPinsUpdate" },
	threadCreate = { intents = { "guilds" }, payload = "Channel" },
	threadUpdate = { intents = { "guilds" }, payload = "Channel" },
	threadDelete = { intents = { "guilds" }, payload = "Channel" },
	threadListSync = { intents = { "guilds" }, payload = "ThreadListSync" },
	threadMemberUpdate = { intents = { "guilds" }, payload = "ThreadMemberUpdate" },
	threadMembersUpdate = { intents = { "guilds", "guildMembers" }, payload = "ThreadMembersUpdate" },
	stageInstanceCreate = { intents = { "guilds" }, payload = "StageInstance" },
	stageInstanceUpdate = { intents = { "guilds" }, payload = "StageInstance" },
	stageInstanceDelete = { intents = { "guilds" }, payload = "StageInstance" },
	voiceChannelStatusUpdate = { intents = { "guilds" }, payload = "VoiceChannelStatusUpdate" },
	voiceChannelStartTimeUpdate = { intents = { "guilds" }, payload = "VoiceChannelStartTimeUpdate" },
	-- guildMembers (privileged)
	guildMemberAdd = { intents = { "guildMembers" }, payload = "GuildMemberEvent" },
	guildMemberUpdate = { intents = { "guildMembers" }, payload = "GuildMemberEvent" },
	guildMemberRemove = { intents = { "guildMembers" }, payload = "GuildMemberRemove" },
	-- guildModeration
	guildAuditLogEntryCreate = { intents = { "guildModeration" }, payload = "GuildAuditLogEntryCreate" },
	guildBanAdd = { intents = { "guildModeration" }, payload = "GuildBanEvent" },
	guildBanRemove = { intents = { "guildModeration" }, payload = "GuildBanEvent" },
	-- guildExpressions
	guildEmojisUpdate = { intents = { "guildExpressions" }, payload = "GuildEmojisUpdate" },
	guildStickersUpdate = { intents = { "guildExpressions" }, payload = "GuildStickersUpdate" },
	guildSoundboardSoundCreate = { intents = { "guildExpressions" }, payload = "SoundboardSound" },
	guildSoundboardSoundUpdate = { intents = { "guildExpressions" }, payload = "SoundboardSound" },
	guildSoundboardSoundDelete = { intents = { "guildExpressions" }, payload = "GuildSoundboardSoundDelete" },
	guildSoundboardSoundsUpdate = { intents = { "guildExpressions" }, payload = "GuildSoundboardSounds" },
	-- guildIntegrations
	guildIntegrationsUpdate = { intents = { "guildIntegrations" }, payload = "GuildIdEvent" },
	integrationCreate = { intents = { "guildIntegrations" }, payload = "IntegrationEvent" },
	integrationUpdate = { intents = { "guildIntegrations" }, payload = "IntegrationEvent" },
	integrationDelete = { intents = { "guildIntegrations" }, payload = "IntegrationDelete" },
	-- guildWebhooks
	webhooksUpdate = { intents = { "guildWebhooks" }, payload = "WebhooksUpdate" },
	-- guildInvites
	inviteCreate = { intents = { "guildInvites" }, payload = "InviteCreateEvent" },
	inviteDelete = { intents = { "guildInvites" }, payload = "InviteDeleteEvent" },
	-- guildVoiceStates
	voiceChannelEffectSend = { intents = { "guildVoiceStates" }, payload = "VoiceChannelEffectSend" },
	voiceStateUpdate = { intents = { "guildVoiceStates" }, payload = "VoiceState" },
	-- guildPresences (privileged)
	presenceUpdate = { intents = { "guildPresences" }, payload = "PresenceUpdate" },
	-- Messages: guildMessages for servers, directMessages for DMs
	messageCreate = { intents = { "guildMessages", "directMessages" }, payload = "Message" },
	messageUpdate = { intents = { "guildMessages", "directMessages" }, payload = "Message" },
	messageDelete = { intents = { "guildMessages", "directMessages" }, payload = "MessageDelete" },
	messageDeleteBulk = { intents = { "guildMessages" }, payload = "MessageDeleteBulk" },
	-- Reactions: guildMessageReactions, directMessageReactions
	messageReactionAdd = { intents = { "guildMessageReactions", "directMessageReactions" }, payload = "MessageReactionAdd" },
	messageReactionRemove = { intents = { "guildMessageReactions", "directMessageReactions" }, payload = "MessageReactionRemove" },
	messageReactionRemoveAll = { intents = { "guildMessageReactions", "directMessageReactions" }, payload = "MessageReactionRemoveAll" },
	messageReactionRemoveEmoji = { intents = { "guildMessageReactions", "directMessageReactions" }, payload = "MessageReactionRemoveEmoji" },
	-- Typing: guildMessageTyping, directMessageTyping
	typingStart = { intents = { "guildMessageTyping", "directMessageTyping" }, payload = "TypingStart" },
	-- guildScheduledEvents
	guildScheduledEventCreate = { intents = { "guildScheduledEvents" }, payload = "ScheduledEvent" },
	guildScheduledEventUpdate = { intents = { "guildScheduledEvents" }, payload = "ScheduledEvent" },
	guildScheduledEventDelete = { intents = { "guildScheduledEvents" }, payload = "ScheduledEvent" },
	guildScheduledEventUserAdd = { intents = { "guildScheduledEvents" }, payload = "GuildScheduledEventUserEvent" },
	guildScheduledEventUserRemove = { intents = { "guildScheduledEvents" }, payload = "GuildScheduledEventUserEvent" },
	-- AutoMod
	autoModerationRuleCreate = { intents = { "autoModerationConfiguration" }, payload = "AutoModRule" },
	autoModerationRuleUpdate = { intents = { "autoModerationConfiguration" }, payload = "AutoModRule" },
	autoModerationRuleDelete = { intents = { "autoModerationConfiguration" }, payload = "AutoModRule" },
	autoModerationActionExecution = { intents = { "autoModerationExecution" }, payload = "AutoModerationActionExecution" },
	-- Polls: guildMessagePolls, directMessagePolls
	messagePollVoteAdd = { intents = { "guildMessagePolls", "directMessagePolls" }, payload = "MessagePollVoteEvent" },
	messagePollVoteRemove = { intents = { "guildMessagePolls", "directMessagePolls" }, payload = "MessagePollVoteEvent" },
} :: { [string]: Entry })

--- The registry's names as a key set, for `Spec.suggest`.
Events.NAMES = (function(): Spec.Keys
	local names = {}
	for name in Events.REGISTRY do
		table.insert(names, name)
	end
	return Spec.keys(names)
end)()

--[[
	The listener type for each event. Handlers return `...any` rather than
	`()` so a listener can end with `return client:reply(...)`; the value
	is ignored.
]]
export type Handlers = {
	-- Library events: raised by the client itself, not sent by Discord
	ready: (Types.Ready) -> ...any,
	shardReady: (number, boolean) -> ...any,
	shardResume: (number) -> ...any,
	shardDisconnect: (number, number?) -> ...any,
	error: (string, string) -> ...any,
	raw: (string, any) -> ...any,
	-- Connection and application (no intent needed)
	resumed: (Loose) -> ...any,
	userUpdate: (Types.User) -> ...any,
	interactionCreate: (Types.Interaction) -> ...any,
	applicationCommandPermissionsUpdate: (Types.GuildApplicationCommandPermissions) -> ...any,
	entitlementCreate: (Types.Entitlement) -> ...any,
	entitlementUpdate: (Types.Entitlement) -> ...any,
	entitlementDelete: (Types.Entitlement) -> ...any,
	subscriptionCreate: (Types.Subscription) -> ...any,
	subscriptionUpdate: (Types.Subscription) -> ...any,
	subscriptionDelete: (Types.Subscription) -> ...any,
	guildMembersChunk: (Types.GuildMembersChunk) -> ...any,
	soundboardSounds: (Types.GuildSoundboardSounds) -> ...any,
	voiceServerUpdate: (Types.VoiceServerUpdate) -> ...any,
	rateLimited: (Types.RateLimited) -> ...any,
	-- guilds
	guildCreate: (Types.Guild) -> ...any,
	guildUpdate: (Types.Guild) -> ...any,
	guildDelete: (Types.UnavailableGuild) -> ...any,
	guildRoleCreate: (Types.GuildRoleEvent) -> ...any,
	guildRoleUpdate: (Types.GuildRoleEvent) -> ...any,
	guildRoleDelete: (Types.GuildRoleDelete) -> ...any,
	channelCreate: (Types.Channel) -> ...any,
	channelUpdate: (Types.Channel) -> ...any,
	channelDelete: (Types.Channel) -> ...any,
	channelPinsUpdate: (Types.ChannelPinsUpdate) -> ...any,
	threadCreate: (Types.Channel) -> ...any,
	threadUpdate: (Types.Channel) -> ...any,
	threadDelete: (Types.Channel) -> ...any,
	threadListSync: (Types.ThreadListSync) -> ...any,
	threadMemberUpdate: (Types.ThreadMemberUpdate) -> ...any,
	threadMembersUpdate: (Types.ThreadMembersUpdate) -> ...any,
	stageInstanceCreate: (Types.StageInstance) -> ...any,
	stageInstanceUpdate: (Types.StageInstance) -> ...any,
	stageInstanceDelete: (Types.StageInstance) -> ...any,
	voiceChannelStatusUpdate: (Types.VoiceChannelStatusUpdate) -> ...any,
	voiceChannelStartTimeUpdate: (Types.VoiceChannelStartTimeUpdate) -> ...any,
	-- guildMembers (privileged)
	guildMemberAdd: (Types.GuildMemberEvent) -> ...any,
	guildMemberUpdate: (Types.GuildMemberEvent) -> ...any,
	guildMemberRemove: (Types.GuildMemberRemove) -> ...any,
	-- guildModeration
	guildAuditLogEntryCreate: (Types.GuildAuditLogEntryCreate) -> ...any,
	guildBanAdd: (Types.GuildBanEvent) -> ...any,
	guildBanRemove: (Types.GuildBanEvent) -> ...any,
	-- guildExpressions
	guildEmojisUpdate: (Types.GuildEmojisUpdate) -> ...any,
	guildStickersUpdate: (Types.GuildStickersUpdate) -> ...any,
	guildSoundboardSoundCreate: (Types.SoundboardSound) -> ...any,
	guildSoundboardSoundUpdate: (Types.SoundboardSound) -> ...any,
	guildSoundboardSoundDelete: (Types.GuildSoundboardSoundDelete) -> ...any,
	guildSoundboardSoundsUpdate: (Types.GuildSoundboardSounds) -> ...any,
	-- guildIntegrations
	guildIntegrationsUpdate: (Types.GuildIdEvent) -> ...any,
	integrationCreate: (Types.IntegrationEvent) -> ...any,
	integrationUpdate: (Types.IntegrationEvent) -> ...any,
	integrationDelete: (Types.IntegrationDelete) -> ...any,
	-- guildWebhooks
	webhooksUpdate: (Types.WebhooksUpdate) -> ...any,
	-- guildInvites
	inviteCreate: (Types.InviteCreateEvent) -> ...any,
	inviteDelete: (Types.InviteDeleteEvent) -> ...any,
	-- guildVoiceStates
	voiceChannelEffectSend: (Types.VoiceChannelEffectSend) -> ...any,
	voiceStateUpdate: (Types.VoiceState) -> ...any,
	-- guildPresences (privileged)
	presenceUpdate: (Types.PresenceUpdate) -> ...any,
	-- Messages: guildMessages for servers, directMessages for DMs
	messageCreate: (Types.Message) -> ...any,
	messageUpdate: (Types.Message) -> ...any,
	messageDelete: (Types.MessageDelete) -> ...any,
	messageDeleteBulk: (Types.MessageDeleteBulk) -> ...any,
	-- Reactions: guildMessageReactions, directMessageReactions
	messageReactionAdd: (Types.MessageReactionAdd) -> ...any,
	messageReactionRemove: (Types.MessageReactionRemove) -> ...any,
	messageReactionRemoveAll: (Types.MessageReactionRemoveAll) -> ...any,
	messageReactionRemoveEmoji: (Types.MessageReactionRemoveEmoji) -> ...any,
	-- Typing: guildMessageTyping, directMessageTyping
	typingStart: (Types.TypingStart) -> ...any,
	-- guildScheduledEvents
	guildScheduledEventCreate: (Types.ScheduledEvent) -> ...any,
	guildScheduledEventUpdate: (Types.ScheduledEvent) -> ...any,
	guildScheduledEventDelete: (Types.ScheduledEvent) -> ...any,
	guildScheduledEventUserAdd: (Types.GuildScheduledEventUserEvent) -> ...any,
	guildScheduledEventUserRemove: (Types.GuildScheduledEventUserEvent) -> ...any,
	-- AutoMod
	autoModerationRuleCreate: (Types.AutoModRule) -> ...any,
	autoModerationRuleUpdate: (Types.AutoModRule) -> ...any,
	autoModerationRuleDelete: (Types.AutoModRule) -> ...any,
	autoModerationActionExecution: (Types.AutoModerationActionExecution) -> ...any,
	-- Polls: guildMessagePolls, directMessagePolls
	messagePollVoteAdd: (Types.MessagePollVoteEvent) -> ...any,
	messagePollVoteRemove: (Types.MessagePollVoteEvent) -> ...any,
}

--[[
	Why a map and type functions, not one overload per event: Luau's
	checker gives up ("code is too complex") on an intersection of more
	than eight function types, and there are over eighty events. A generic
	overload whose event parameter is `E & keyof<Handlers>` keeps the
	string literal's singleton type (a bare `E` would widen it to
	`string`), and these look the listener type up by it.
]]
type function HandlerOf(map, event)
	local found = if event:is("singleton") then map:readproperty(event) else nil
	return found or types.newfunction({ tail = types.any }, { tail = types.any })
end

--- The listener's parameters, returning boolean: a `waitFor` filter.
type function FilterOf(map, event)
	local found = if event:is("singleton") then map:readproperty(event) else nil
	if found == nil then
		return types.newfunction({ tail = types.any }, { head = { types.boolean } })
	end
	return types.newfunction((found :: any):parameters(), { head = { types.boolean } })
end

--- The listener's first parameter, made optional: what `waitFor` returns.
type function FirstOf(map, event)
	local found = if event:is("singleton") then map:readproperty(event) else nil
	if found == nil then
		return types.any
	end
	local head = (found :: any):parameters().head
	if head == nil or #head == 0 then
		return types.any
	end
	return types.optional(head[1])
end

--[[
	`client:on` and `client:once`. The second overload takes any other
	name, because `client:emit` with a name of your own is legitimate.

	A limit of Luau 1.0.0's checker, for any overloaded or generic function
	that takes a callback: an operator applied straight to an unannotated
	parameter can be checked before the parameter's type is known, and
	fails with "Operator '..' could not be applied to operands of types
	string and unknown" (`"hi " .. m.author.username`). Annotating the
	parameter fixes it, and the annotation is still checked against the
	event: `function(m: Discord.Message)`.
]]
export type On =
	(<E>(self: any, event: E & keyof<Handlers>, fn: HandlerOf<Handlers, E>) -> number)
	& ((self: any, event: string, fn: (...any) -> ...any) -> number)

--[[
	`client:waitFor`. The filter's parameters are inferred from the event.

	The return is NOT typed: a known name matches the string overload as
	well as the typed one, and Luau resolves that ambiguity to `any`.
	Dropping the string overload would type the return but reject custom
	events. Annotate the result (`local reply: Discord.Message? = ...`).
]]
export type WaitFor =
	(<E>(self: any, event: E & keyof<Handlers>, filter: FilterOf<Handlers, E>?, timeout: number?) -> (FirstOf<Handlers, E>, ...any))
	& ((self: any, event: string, filter: ((...any) -> boolean)?, timeout: number?) -> ...any)

--- Whether `name` is an event the library or Discord raises.
function Events.isKnown(name: string): boolean
	return Events.REGISTRY[name] ~= nil
end

--- The event the caller probably meant by an unknown `name`, or nil.
function Events.suggest(name: string): string?
	return Spec.suggest(name, Events.NAMES)
end

--- Whether intent `name` is set in `mask`.
function Events.hasIntent(mask: number, name: string): boolean
	local bit = (Const.IntentBits :: { [string]: number })[name]
	return bit ~= nil and bit32.btest(mask, 2 ^ bit)
end

--[[
	The intents that would deliver `event` when `mask` enables none of them,
	or nil when it will arrive (or is unknown, or needs no intent). Taking
	the mask rather than the names is what makes a raw-number `intents`
	option work the same as a list.
]]
function Events.missingIntents(event: string, mask: number): { string }?
	local entry = Events.REGISTRY[event]
	if entry == nil or #entry.intents == 0 then
		return nil
	end
	for _, intent in entry.intents do
		if Events.hasIntent(mask, intent) then
			return nil
		end
	end
	return entry.intents
end

--[[
	Whether `event` loses its message text without `messageContent`.
	AutoMod executions lose `content` too, but a bot listening for those
	acts on the rule that matched, not on the text.
]]
function Events.needsMessageContent(event: string): boolean
	return event == "messageCreate" or event == "messageUpdate"
end

return Events
