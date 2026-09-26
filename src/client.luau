--!strict
--[[
	The client: shards, events, routing, and the bits that tie them together.

	Responsibilities, in the order a bot meets them:

	  1. Turn intent names into the bitmask IDENTIFY wants, and name any
	     privileged ones at startup -- whether they are enabled is only
	     known to Discord, which closes with 4014 if they are not.
	  2. Own the shards, and serialise their IDENTIFYs -- Discord allows one
	     per five seconds per bucket and answers a burst by closing sockets.
	  3. Keep the cache in step with the gateway.
	  4. Route: gateway events to listeners, slash commands to their handler
	     by full subcommand path, component clicks to collectors first and
	     custom-id prefixes second, modal submits by prefix.
	  5. Contain failures. Every handler runs under `xpcall`; a throw logs a
	     traceback, tells the user something went wrong if an interaction is
	     still unanswered, and leaves the shard running.

	Handlers run on their own scheduler task, so a slow one -- an API call, a
	sleep -- does not hold up the socket or the other handlers.
]]
local task = require("@lute/task")

local Api = require("@discord/api")
local Cache = require("@discord/cache")
local Collector = require("@discord/collector")
local Const = require("@discord/const")
local ApiError = require("@discord/error")
local Gateway = require("@discord/gateway")
local Http = require("@discord/http")
local Interaction = require("@discord/interaction")
local Log = require("@discord/log")
local Payload = require("@discord/payload")
local Types = require("@discord/types")
local Util = require("@discord/util")

local Client = {}
Client.__index = Client

export type Options = {
	token: string,
	--- Intent names (see `Const.IntentBits`) or a raw bitmask.
	intents: { string } | number,
	--- Keep guilds, channels, roles and seen members in memory. Default true.
	cache: boolean?,
	--- debug | info | warn | error. Omitted leaves the level as it is
	--- ("info" unless the bot called `Log.setLevel` itself).
	logLevel: string?,
	--- Mirror the log to this file as well as stdout. Omitted leaves any
	--- `Log.setFile` the bot already made in place.
	logFile: string?,
	--- Number of shards. Omitted means "ask Discord".
	shardCount: number?,
	--- Initial presence, e.g. `Client.presence("watching", "the void")`.
	presence: Types.Presence?,
	--- Reply text when a handler throws. Set to false for silence.
	errorMessage: (string | boolean)?,
	--- Passed to `Http.new`: a custom transport, base URL, retry count.
	http: Http.HttpOptions?,
	--- Passed to every shard, and the identify pacing. See `GatewayTuning`.
	gateway: GatewayTuning?,
}

--[[
	Knobs for the shards. None of these need touching to run a bot: they
	exist so the test suite can swap the socket for a fake and shrink the
	timers from seconds to milliseconds, and so a bot can dial a gateway
	proxy.
]]
export type GatewayTuning = {
	connect: Gateway.Connect?,
	--- Overrides the URL GET /gateway/bot returns.
	gatewayUrl: string?,
	backoffBase: number?,
	backoffCap: number?,
	sendLimit: number?,
	sendWindow: number?,
	--- Seconds between IDENTIFYs in one concurrency bucket. Default 5.2:
	--- Discord's 5 s plus slack for clock skew between us and them.
	identifyInterval: number?,
}

export type FetchMembersOptions = {
	--- Members whose username starts with this. "" (the default) with
	--- `limit = 0` means every member, which needs the GUILD_MEMBERS intent.
	query: string?,
	limit: number?,
	--- Look up specific members instead of searching (max 100).
	userIds: { string }?,
	presences: boolean?,
	--- Seconds to wait for the last chunk. Default 30.
	timeout: number?,
}

--- An outstanding op 8 request, filled in by GUILD_MEMBERS_CHUNK.
type MemberRequestState = {
	guildId: string,
	members: { Types.Member },
	notFound: { string },
	received: number,
	done: boolean,
}

--[[
	A registered listener.

	`fn` takes `any` because the event bus is keyed by string and every one of
	the sixty-odd gateway events carries a different payload -- Luau has no
	way to tie the name to the shape. Handlers annotate their own parameter
	(`function(message: Types.Message)`) and get checked from there; the
	`Types` module is what says which shape goes with which name.
]]
type Listener = { id: number, event: string, fn: (any, any) -> (), once: boolean }

type Route = { prefix: string, fn: (Interaction.Interaction) -> () }

export type Client = typeof(setmetatable(
	{} :: {
		options: Options,
		token: string,
		intents: number,
		http: Http.Http,
		api: Api.Api,
		cache: Cache.Cache,
		shards: { Gateway.Gateway },
		user: Types.User?,
		applicationId: string?,
		startedAt: Util.Instant,
		running: boolean,
		_listeners: { [string]: { Listener } },
		_commands: { [string]: (Interaction.Interaction) -> () },
		_autocompletes: { [string]: (Interaction.Interaction) -> () },
		_components: { Route },
		_modals: { Route },
		_collectors: { [Collector.Collector]: boolean },
		_nextListenerId: number,
		--- Shards in this run, fixed when `login` asks Discord.
		shardCount: number,
		--- Why the client stopped, if a shard hit a fatal close code.
		fatalReason: string?,
		--- Shards that have completed a READY this run; `ready` fires when
		--- this covers every shard. Not cleared on disconnect, so a shard
		--- dropping mid-startup does not hold `ready` back forever.
		_readyShards: { [number]: boolean },
		_readyEmitted: boolean,
		_memberRequests: { [string]: MemberRequestState },
	},
	{} :: typeof(Client)
))

----------------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------------

--[[
	Resolves intent names to a mask, and says so loudly when one of them is
	privileged.

	A privileged intent that is not ticked in the developer portal does not
	degrade -- it closes the socket with 4014 on every connect. Naming the
	specific intents at startup is the difference between a one-minute fix
	and an afternoon.
]]
local function resolveIntents(intents: { string } | number): number
	if type(intents) == "number" then
		return intents
	end
	local mask = 0
	local privileged = {}
	for _, name in intents do
		local bit = (Const.IntentBits :: { [string]: number })[name]
		if bit == nil then
			error(`unknown intent "{name}"`, 3)
		end
		mask = bit32.bor(mask, 2 ^ bit)
		if (Const.PRIVILEGED_INTENTS :: { [string]: boolean })[name] then
			table.insert(privileged, name)
		end
	end
	if #privileged > 0 then
		Log.info(
			`using privileged intent(s): {table.concat(privileged, ", ")} -- these must be enabled under `
				.. "Bot > Privileged Gateway Intents in the Discord developer portal"
		)
	end
	return mask
end

function Client.new(options: Options): Client
	-- Only what was asked for: the log is process-wide, and resetting it
	-- here would undo a `Log.setFile` the bot made before constructing us.
	if options.logLevel ~= nil then
		Log.setLevel(options.logLevel)
	end
	if options.logFile ~= nil then
		Log.setFile(options.logFile)
	end

	local http = Http.new(options.token, options.http)
	return setmetatable({
		options = options,
		token = options.token,
		intents = resolveIntents(options.intents),
		http = http,
		api = Api.new(http),
		cache = Cache.new(options.cache ~= false),
		shards = {},
		user = nil :: Types.User?,
		applicationId = nil :: string?,
		startedAt = Util.now(),
		running = false,
		_listeners = {},
		_commands = {},
		_autocompletes = {},
		_components = {},
		_modals = {},
		_collectors = {},
		_nextListenerId = 1,
		shardCount = options.shardCount or 1,
		fatalReason = nil :: string?,
		_readyShards = {},
		_readyEmitted = false,
		_memberRequests = {},
	}, Client)
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

--- `MESSAGE_REACTION_ADD` -> `messageReactionAdd`.
local function camel(event: string): string
	local spaced = (string.gsub(event, "_", " "))
	local lowered = string.lower(spaced)
	return (string.gsub(lowered, " (%l)", string.upper))
end

Client.eventName = camel

--[[
	Registers a listener. Event names are camelCase versions of the gateway's
	(`messageCreate`, `guildMemberAdd`), plus a few the library raises itself:

	  * `ready`           -- EVERY shard has completed its first READY; fires
	                         once per `login`/`run`. Payload is the READY
	                         object of the shard that completed the set -- for
	                         a single-shard bot, its only READY, exactly as
	                         before. (Earlier versions fired `ready` once per
	                         shard; use `shardReady` for that.)
	  * `shardReady`      -- `(shardId, resumed)` each time a shard becomes
	                         usable: after READY (`false`) or RESUMED (`true`)
	  * `shardResume`     -- `(shardId)` after a successful RESUME
	  * `shardDisconnect` -- `(shardId, closeCode?)` whenever a shard's socket
	                         closes; it reconnects on its own unless fatal
	  * `resumed`         -- the RESUMED dispatch, as before
	  * `error`           -- a handler threw; payload is `(err, context)`
	  * `raw`             -- every dispatch, as `(eventName, data)`

	Returns a handle for `off`.
]]
function Client.on(self: Client, event: string, fn: (any, any) -> ()): number
	local list = self._listeners[event]
	if list == nil then
		list = {}
		self._listeners[event] = list
	end
	assert(list ~= nil)
	local id = self._nextListenerId
	self._nextListenerId += 1
	table.insert(list, { id = id, event = event, fn = fn, once = false })
	return id
end

function Client.once(self: Client, event: string, fn: (any, any) -> ()): number
	local id = Client.on(self, event, fn)
	local list = self._listeners[event]
	if list ~= nil then
		list[#list].once = true
	end
	return id
end

function Client.off(self: Client, id: number)
	for _, list in self._listeners do
		for index, listener in list do
			if listener.id == id then
				table.remove(list, index)
				return
			end
		end
	end
end

--[[
	Yields until `event` fires with arguments `filter` accepts, and returns
	those arguments -- or nil once `timeout` seconds pass. No timeout means
	wait forever.

	    local reply = client:waitFor("messageCreate", function(m)
	        return m.author.id == ix.user.id and m.channel_id == ix.channelId
	    end, 60)

	A filter that throws counts as "no" (and is logged); it must not leave
	the caller hanging.
]]
function Client.waitFor(
	self: Client,
	event: string,
	filter: ((any, any) -> boolean)?,
	timeout: number?
): (any, any)
	local done = false
	local first: any, second: any = nil, nil
	local id: number = 0
	id = Client.on(self, event, function(a: any, b: any)
		if done then
			return
		end
		if filter ~= nil then
			local ok, accepted = pcall(filter, a, b)
			if not ok then
				Log.warn(`waitFor("{event}") filter failed: {tostring(accepted)}`)
				return
			end
			if not accepted or done then
				return
			end
		end
		done = true
		first, second = a, b
		Client.off(self, id)
	end)
	-- A poll, like `Collector.await`: Lute has no primitive to wake one
	-- thread from another, and 20ms is invisible next to a human typing.
	local started = Util.now()
	while not done and (timeout == nil or Util.since(started) < timeout) do
		task.wait(0.02)
	end
	if not done then
		done = true
		Client.off(self, id)
	end
	return first, second
end

--- Runs each listener on its own task: one slow handler must not delay the
--- next, and a throw must not escape into the gateway loop.
function Client.emit(self: Client, event: string, first: any, second: any)
	local list = self._listeners[event]
	if list == nil then
		return
	end
	local snapshot = table.clone(list)
	for _, listener in snapshot do
		if listener.once then
			Client.off(self, listener.id)
		end
		task.spawn(function()
			local ok, err = xpcall(function(): boolean
				listener.fn(first, second)
				return true
			end, function(message: unknown): string
				return debug.traceback(tostring(message), 2)
			end)
			if not ok then
				Log.error(`listener for "{event}" failed:\n{tostring(err)}`)
				if event ~= "error" then
					Client.emit(self, "error", err, event)
				end
			end
		end)
	end
end

----------------------------------------------------------------------------
-- Command routing
----------------------------------------------------------------------------

--[[
	Handles `/name`, or a subcommand path like `"role add"`.

	Register the most specific path you handle: routing tries the full path
	first and then falls back to the bare command name, so a command with
	subcommands can either handle each one separately or take them all in a
	single handler.
]]
function Client.command(self: Client, path: string, fn: (Interaction.Interaction) -> ()): Client
	self._commands[path] = fn
	return self
end

--- Handles autocomplete for a command path.
function Client.autocomplete(self: Client, path: string, fn: (Interaction.Interaction) -> ()): Client
	self._autocompletes[path] = fn
	return self
end

--[[
	Handles component clicks whose `custom_id` starts with `prefix`.

	Prefix matching is what makes dynamic components workable: encode state in
	the id (`poll:1234:yes`), register one handler for `poll:`, and parse the
	rest. Longer prefixes win, so a specific id can override a general one.
]]
function Client.component(self: Client, prefix: string, fn: (Interaction.Interaction) -> ()): Client
	table.insert(self._components, { prefix = prefix, fn = fn })
	table.sort(self._components, function(a: Route, b: Route): boolean
		return #a.prefix > #b.prefix
	end)
	return self
end

--- Handles modal submissions whose `custom_id` starts with `prefix`.
function Client.modal(self: Client, prefix: string, fn: (Interaction.Interaction) -> ()): Client
	table.insert(self._modals, { prefix = prefix, fn = fn })
	table.sort(self._modals, function(a: Route, b: Route): boolean
		return #a.prefix > #b.prefix
	end)
	return self
end

--- Starts a collector. See `@discord/collector`.
function Client.collect(self: Client, options: Collector.Options): Collector.Collector
	return Collector.new(self, options)
end

--[[
	Runs a command handler with a safety net.

	If it throws, the user gets one ephemeral apology (never a raw traceback
	-- Discord errors routinely quote ids and tokens) and the traceback goes
	to the log. If the interaction was never answered at all, answering it
	here is what stops the client showing "application did not respond".
]]
local function runHandler(self: Client, ix: Interaction.Interaction, fn: (Interaction.Interaction) -> (), label: string)
	task.spawn(function()
		-- Logged before the handler runs, not after, so a handler that hangs
		-- still leaves a record of what was invoked.
		local user = ix.user
		if user ~= nil then
			Log.debug(`{label} by {user.username} ({user.id})`)
		end
		local ok, err = xpcall(function(): boolean
			fn(ix)
			return true
		end, function(message: unknown): string
			if ApiError.is(message) then
				return tostring(message)
			end
			return debug.traceback(tostring(message), 2)
		end)
		if ok then
			return
		end

		Log.error(`{label} failed:\n{tostring(err)}`)
		Client.emit(self, "error", err, label)

		local notice = self.options.errorMessage
		if notice == false or ix.type == Const.InteractionType.APPLICATION_COMMAND_AUTOCOMPLETE then
			return
		end
		local text = if type(notice) == "string" then notice else "Something went wrong running that."
		pcall(function()
			if ix.deferred then
				-- A follow-up would leave the "thinking..." placeholder up
				-- forever; the notice has to replace it. Its visibility was
				-- fixed by the deferral and cannot be changed now.
				Interaction.editReply(ix, { content = text })
			elseif ix.acknowledged then
				Interaction.followUp(ix, { content = text, ephemeral = true })
			else
				Interaction.replyEphemeral(ix, text)
			end
		end)
	end)
end

local function routeInteraction(self: Client, raw: Types.Interaction)
	local ix = Interaction.new(self, raw)

	if raw.type == Const.InteractionType.APPLICATION_COMMAND then
		local path = Interaction.commandPath(ix)
		local handler = self._commands[path] or self._commands[(string.match(path, "^(%S+)") :: string)]
		if handler == nil then
			Log.warn(`no handler registered for command "{path}"`)
			-- On its own task and under pcall: a failed reply is a REST
			-- error, and letting it escape here would skip the
			-- `interactionCreate` emit that follows routing.
			task.spawn(pcall, Interaction.replyEphemeral, ix, `\`/{path}\` is not wired up on this bot.`)
			return
		end
		runHandler(self, ix, handler, `command /{path}`)
	elseif raw.type == Const.InteractionType.APPLICATION_COMMAND_AUTOCOMPLETE then
		local path = Interaction.commandPath(ix)
		local handler = self._autocompletes[path] or self._autocompletes[(string.match(path, "^(%S+)") :: string)]
		if handler == nil then
			-- An empty list is the only honest answer, and it stops the
			-- client from showing a spinner forever.
			task.spawn(pcall, Interaction.autocomplete, ix, {} :: { Types.AutocompleteChoice })
			return
		end
		runHandler(self, ix, handler, `autocomplete /{path}`)
	elseif raw.type == Const.InteractionType.MESSAGE_COMPONENT then
		-- Collectors get first refusal: they are scoped to one message and
		-- are the more specific listener by construction.
		for collector in self._collectors do
			if Collector.push(collector, ix) then
				return
			end
		end
		local customId = (raw.data and raw.data.custom_id) or ""
		for _, entry in self._components do
			if string.sub(customId, 1, #entry.prefix) == entry.prefix then
				runHandler(self, ix, entry.fn, `component {customId}`)
				return
			end
		end
		-- Nothing is listening: the component outlived its handler, which is
		-- normal after a restart. Acknowledge so the client stops spinning.
		Log.debug(`unhandled component "{customId}"`)
		task.spawn(pcall, Interaction.deferUpdate, ix)
	elseif raw.type == Const.InteractionType.MODAL_SUBMIT then
		-- Same first refusal as components: a collector waiting on a modal
		-- it opened is more specific than any prefix route.
		for collector in self._collectors do
			if Collector.push(collector, ix) then
				return
			end
		end
		local customId = (raw.data and raw.data.custom_id) or ""
		for _, entry in self._modals do
			if string.sub(customId, 1, #entry.prefix) == entry.prefix then
				runHandler(self, ix, entry.fn, `modal {customId}`)
				return
			end
		end
		Log.warn(`unhandled modal "{customId}"`)
		task.spawn(pcall, Interaction.replyEphemeral, ix, "That form is no longer accepting submissions.")
	end
end

----------------------------------------------------------------------------
-- Cache maintenance
----------------------------------------------------------------------------

--[[
	Folds one dispatch into the cache.

	`data` is `any` for the same reason `Json.decode` returns `any`: this is
	the seam where a socket payload becomes a typed object, and which object
	it is depends on `event`. Each branch below is the place that decides,
	and hands a named type to the cache from there.
]]
local function updateCache(self: Client, event: string, data: any)
	local cache = self.cache
	if data == nil then
		return
	end
	-- The bot's own user is kept even with the cache off: it is one object,
	-- and `client.user` going stale after a rename is a bug, not a saving.
	if event == "READY" then
		Cache.setSelf(cache, data.user)
	elseif event == "USER_UPDATE" then
		local me = self.user
		if me == nil or data.id == me.id then
			self.user = data
			Cache.setSelf(cache, data)
		end
	end
	if not cache.enabled then
		return
	end

	if event == "GUILD_CREATE" then
		Cache.putGuild(cache, data)
	elseif event == "GUILD_UPDATE" then
		Cache.patchGuild(cache, data)
	elseif event == "GUILD_DELETE" then
		if data.unavailable == true then
			-- An outage, not a removal: keep the data, flag the guild.
			local known = cache.guilds[data.id]
			if known ~= nil then
				known.unavailable = true
			end
		else
			Cache.removeGuild(cache, data.id)
		end
	elseif
		event == "CHANNEL_CREATE"
		or event == "CHANNEL_UPDATE"
		or event == "THREAD_CREATE"
		or event == "THREAD_UPDATE"
	then
		Cache.putChannel(cache, data)
	elseif event == "CHANNEL_DELETE" or event == "THREAD_DELETE" then
		Cache.removeChannel(cache, data.id)
	elseif event == "THREAD_LIST_SYNC" then
		Cache.syncThreads(cache, data.guild_id, data.channel_ids, data.threads or {})
	elseif event == "GUILD_EMOJIS_UPDATE" then
		Cache.setEmojis(cache, data.guild_id, data.emojis or {})
	elseif event == "GUILD_STICKERS_UPDATE" then
		Cache.setStickers(cache, data.guild_id, data.stickers or {})
	elseif event == "GUILD_ROLE_CREATE" or event == "GUILD_ROLE_UPDATE" then
		Cache.putRole(cache, data.guild_id, data.role)
	elseif event == "GUILD_ROLE_DELETE" then
		Cache.removeRole(cache, data.guild_id, data.role_id)
	elseif event == "GUILD_MEMBER_ADD" then
		Cache.putMember(cache, data.guild_id, data)
	elseif event == "GUILD_MEMBER_UPDATE" then
		Cache.patchMember(cache, data.guild_id, data)
	elseif event == "GUILD_MEMBER_REMOVE" then
		local removed: Types.User? = data.user
		if removed ~= nil then
			Cache.removeMember(cache, data.guild_id, removed.id)
		end
	elseif event == "GUILD_MEMBERS_CHUNK" then
		for _, member in data.members or {} do
			Cache.putMember(cache, data.guild_id, member)
		end
	elseif event == "MESSAGE_CREATE" then
		local author: Types.User? = data.author
		local member: Types.Member? = data.member
		local guildId: string? = data.guild_id
		Cache.putUser(cache, author)
		if member ~= nil and guildId ~= nil and author ~= nil then
			member.user = author
			Cache.putMember(cache, guildId, member)
		end
	elseif event == "INTERACTION_CREATE" then
		local member: Types.Member? = data.member
		local guildId: string? = data.guild_id
		if member ~= nil and guildId ~= nil then
			Cache.putMember(cache, guildId, member)
		else
			Cache.putUser(cache, data.user)
		end
	end
end

--- Feeds a GUILD_MEMBERS_CHUNK to the `fetchMembers` call waiting on its
--- nonce. Chunks are counted rather than trusting `chunk_index` order.
local function collectChunk(self: Client, data: any)
	local nonce = data.nonce
	local state = if type(nonce) == "string" then self._memberRequests[nonce] else nil
	if state == nil then
		return
	end
	for _, member in data.members or {} do
		table.insert(state.members, member)
	end
	for _, id in data.not_found or {} do
		table.insert(state.notFound, tostring(id))
	end
	state.received += 1
	local count = tonumber(data.chunk_count) or 1
	if state.received >= count then
		state.done = true
	end
end

local function onDispatch(self: Client, shardId: number, event: string, data: any)
	updateCache(self, event, data)

	if event == "READY" then
		self.user = data.user
		self.applicationId = data.application and data.application.id or data.user.id
		Log.setPrefix(data.user.username)
	end

	Client.emit(self, "raw", event, data)

	if event == "INTERACTION_CREATE" then
		routeInteraction(self, data)
	elseif event == "GUILD_MEMBERS_CHUNK" then
		collectChunk(self, data)
	end

	if event == "READY" then
		self._readyShards[shardId] = true
		Client.emit(self, "shardReady", shardId, false)
		if not self._readyEmitted then
			local count = 0
			for _ in self._readyShards do
				count += 1
			end
			if count >= self.shardCount then
				self._readyEmitted = true
				Client.emit(self, "ready", data)
			end
		end
		return
	elseif event == "RESUMED" then
		Client.emit(self, "shardReady", shardId, true)
		Client.emit(self, "shardResume", shardId)
	end

	Client.emit(self, camel(event), data)
end

--[[
	Feeds a dispatch through the client exactly as a shard would: cache,
	`raw`, routing, then the camelCase event. The seam the test suite uses
	to drive routing and the cache without a socket; a bot has no need for
	it.
]]
function Client._dispatch(self: Client, event: string, data: any, shardId: number?)
	onDispatch(self, shardId or 0, event, data)
end

----------------------------------------------------------------------------
-- Convenience wrappers
----------------------------------------------------------------------------

function Client.send(self: Client, channelId: string, payload: Types.MessageInput): Types.Message
	return self.api.channels.createMessage(channelId, payload)
end

--- Replies to a message, as a real Discord reply, without pinging the author.
--- The no-ping default is deliberate: bots that ping on every reply are the
--- reason people mute bot channels.
function Client.reply(
	self: Client,
	message: Types.Message,
	payload: Types.MessageInput,
	ping: boolean?
): Types.Message
	local body = Payload.copy(payload)
	body.message_reference = { message_id = message.id, channel_id = message.channel_id }
	if not ping then
		body.allowed_mentions = { parse = {}, replied_user = false }
	end
	return self.api.channels.createMessage(message.channel_id, body)
end

--- Opens a DM and sends to it. Fails with 403 if the user has DMs closed,
--- which is common and not worth treating as an error.
function Client.dm(self: Client, userId: string, payload: Types.MessageInput): Types.Message?
	local ok, result = pcall(function()
		local channel = self.api.users.createDm(userId)
		return self.api.channels.createMessage(channel.id, payload)
	end)
	if not ok then
		Log.debug(`could not DM {userId}: {tostring(result)}`)
		return nil
	end
	return result
end

--- Builds a presence payload. `kind` is playing/streaming/listening/watching/
--- competing/custom.
function Client.presence(kind: string, text: string, options: { status: string?, url: string? }?): Types.Presence
	local types: { [string]: number } = {
		playing = Const.ActivityType.PLAYING,
		streaming = Const.ActivityType.STREAMING,
		listening = Const.ActivityType.LISTENING,
		watching = Const.ActivityType.WATCHING,
		custom = Const.ActivityType.CUSTOM,
		competing = Const.ActivityType.COMPETING,
	}
	local activity: Types.Activity = { name = text, type = types[kind] or Const.ActivityType.PLAYING }
	if kind == "custom" then
		-- Custom status shows `state`, not `name`, but `name` is still
		-- required by the schema.
		activity.state = text
	end
	if options and options.url then
		activity.url = options.url
	end
	return {
		activities = { activity },
		status = (options and options.status) or "online",
		afk = false,
		since = 0,
	}
end

--[[
	Changes presence on every shard. Each shard remembers it for its next
	IDENTIFY before trying to send, so an update that is queued (the shard
	has not authenticated yet) or refused (it is between connections) still
	takes effect on reconnect instead of reverting to the startup presence.
	A client that has not connected yet starts with it.
]]
function Client.setPresence(self: Client, presence: Types.Presence)
	self.options.presence = presence
	for _, shard in self.shards do
		Gateway.updatePresence(shard, presence)
	end
end

--[[
	Which shard a guild lives on: `(guild_id >> 22) % shardCount`.

	The id is a 64-bit decimal STRING, and `tonumber` on it rounds away the
	low bits -- close enough to look right, wrong often enough to send a
	request to a shard that does not know the guild. So the shift is long
	division on the digits, as in `@discord/snowflake`; the quotient (~42
	bits) is exact in a double.
]]
function Client.shardFor(self: Client, guildId: string): number
	local quotient = 0
	local remainder = 0
	for index = 1, #guildId do
		local digit = string.byte(guildId, index) - 48
		if digit < 0 or digit > 9 then
			error(`not a snowflake: {guildId}`, 2)
		end
		local current = remainder * 10 + digit
		quotient = quotient * 10 + math.floor(current / 4194304)
		remainder = current % 4194304
	end
	return quotient % math.max(1, self.shardCount)
end

--- The shard object for a guild, or nil before the client has connected.
local function shardOf(self: Client, guildId: string): Gateway.Gateway?
	return self.shards[Client.shardFor(self, guildId) + 1]
end

--[[
	Fetches guild members over the gateway (op 8) and returns them; they are
	cached as they arrive. The second return value lists the `userIds` that
	were not found.

	Everything but a `userIds` lookup needs the GUILD_MEMBERS privileged
	intent -- without it Discord answers with nothing and this times out.
	Throws if the guild's shard is not connected, or on timeout.
]]
function Client.fetchMembers(
	self: Client,
	guildId: string,
	options: FetchMembersOptions?
): ({ Types.Member }, { string })
	local opts: FetchMembersOptions = options or {}
	local shard = shardOf(self, guildId)
	if shard == nil then
		error("fetchMembers needs a connected client; call login() or run() first", 2)
	end
	-- Hex from the seeded RNG. The nonce is how chunks find their request
	-- when several are in flight on one shard; Discord caps it at 32 bytes.
	local nonce = string.format("%08x%08x", math.random(0, 0xFFFFFFFF), math.random(0, 0xFFFFFFFF))
	local state: MemberRequestState = { guildId = guildId, members = {}, notFound = {}, received = 0, done = false }
	self._memberRequests[nonce] = state

	local request: Types.MemberRequest = { nonce = nonce, presences = opts.presences }
	if opts.userIds ~= nil then
		request.user_ids = opts.userIds
		request.limit = opts.limit
	else
		request.query = opts.query or ""
		request.limit = opts.limit or 0
	end
	if not Gateway.requestGuildMembers(shard :: Gateway.Gateway, guildId, request) then
		self._memberRequests[nonce] = nil
		error(`shard {Client.shardFor(self, guildId)} is not connected`, 2)
	end

	local timeout = opts.timeout or 30
	local started = Util.now()
	while not state.done and Util.since(started) < timeout do
		task.wait(0.02)
	end
	self._memberRequests[nonce] = nil
	if not state.done then
		error(
			`member request for guild {guildId} timed out after {timeout}s `
				.. `({state.received} chunk(s) received) -- is the GUILD_MEMBERS intent enabled?`,
			2
		)
	end
	return state.members, state.notFound
end

--[[
	Joins, moves or leaves (`channelId = nil`) a voice channel, on the right
	shard. Voice STATE only -- the bot appears in the channel but cannot
	send or receive audio; see `@discord/gateway`. Returns false when that
	shard is not connected.
]]
function Client.updateVoiceState(
	self: Client,
	guildId: string,
	channelId: string?,
	selfMute: boolean?,
	selfDeaf: boolean?
): boolean
	local shard = shardOf(self, guildId)
	if shard == nil then
		return false
	end
	return Gateway.updateVoiceState(shard :: Gateway.Gateway, guildId, channelId, selfMute, selfDeaf)
end

--- Seconds since the client started.
function Client.uptime(self: Client): number
	return Util.since(self.startedAt)
end

--- Mean heartbeat round trip across shards, in seconds.
function Client.latency(self: Client): number
	if #self.shards == 0 then
		return 0
	end
	local total = 0
	for _, shard in self.shards do
		total += shard.latency
	end
	return total / #self.shards
end

--[[
	Runs a startup step, turning a thrown `ApiError` into its text.

	Lute's top level prints nothing at all for an uncaught error that is a
	table -- not even `table: 0x...` -- so a revoked token at startup would
	show as a bare stack trace with no message. `deploy`, `login` and `run`
	are the calls a bot makes from the top level, so they raise strings.
	Everywhere else (handlers, your own pcalls) the error stays an
	`ApiError` object you can inspect.
]]
local function startup(fn: () -> any): any
	local ok, result = pcall(fn)
	if not ok then
		if not ApiError.is(result) then
			error(result, 0)
		end
		local text = tostring(result)
		if (result :: ApiError.ApiError).status == 401 then
			-- At startup a 401 has one cause, and the message does not say it.
			text ..= "\n  the bot token is invalid or has been reset; copy a fresh one from "
				.. "the developer portal (Bot > Reset Token)"
		end
		error(text, 0)
	end
	return result
end

--[[
	Publishes a command set, replacing whatever was there.

	With a `guildId` the change is instant, which is what you want while
	developing; globally it can take up to an hour to appear. Same call
	either way, so promoting a bot to global is a one-argument change.
]]
function Client.deploy(
	self: Client,
	commands: { Api.CommandInput },
	guildId: string?
): { Types.ApplicationCommand }
	return startup(function()
		return Client._deploy(self, commands, guildId)
	end)
end

function Client._deploy(
	self: Client,
	commands: { Api.CommandInput },
	guildId: string?
): { Types.ApplicationCommand }
	-- Deploy is often called before connecting; fetch the id rather than
	-- forcing the caller to order things carefully.
	local appId: string = self.applicationId or self.api.applications.getCurrent().id
	self.applicationId = appId
	local payload: { Api.CommandInput } = {}
	for _, command in commands do
		table.insert(payload, Payload.toJSON(command))
	end
	local result = if guildId ~= nil
		then self.api.applications.bulkOverwriteGuildCommands(appId, guildId, payload)
		else self.api.applications.bulkOverwriteGlobalCommands(appId, payload)
	Log.info(`deployed {#result} command(s){if guildId then " to guild " .. guildId else " globally"}`)
	return result
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------

--[[
	The identify pacer for `max_concurrency`.

	Discord's rule: a shard's IDENTIFY rate-limit key is
	`shard_id % max_concurrency`, and each key allows one IDENTIFY per five
	seconds. Big bots get max_concurrency 16 or more, so treating it as one
	global queue makes a 64-shard restart take five minutes instead of
	twenty seconds. Slots are reserved before waiting, so two shards of the
	same key that arrive together are spaced out rather than both passing.

	Returns two pacers over separate slot books. The first spaces DIALS, so
	a shard waiting its turn is not holding an unauthenticated socket open.
	The second spaces the IDENTIFYs themselves, run right before each one is
	sent: handshakes take variable time, and a slow one followed by a fast
	one would otherwise put two IDENTIFYs of one key closer than the dials
	were. With the dials already spaced, the second rarely waits, and never
	longer than one interval.

	Both wait in slices and return early once `awake()` is false, so
	`stop()` is not held up by shards queued for a slot minutes out.
]]
local function makeIdentifyGate(
	maxConcurrency: number,
	interval: number
): ((shardId: number, awake: (() -> boolean)?) -> (), (shardId: number, awake: (() -> boolean)?) -> ())
	local epoch = Util.now()
	local buckets = math.max(1, math.floor(maxConcurrency))
	local function pacer(): (shardId: number, awake: (() -> boolean)?) -> ()
		local nextSlot: { [number]: number } = {}
		return function(shardId: number, awake: (() -> boolean)?)
			local key = shardId % buckets
			local now = Util.since(epoch)
			local slot = math.max(now, nextSlot[key] or 0)
			nextSlot[key] = slot + interval
			if slot > now then
				Util.sleepWhile(slot - now, awake or function(): boolean
					return true
				end, 0.05)
			end
		end
	end
	return pacer(), pacer()
end

Client._makeIdentifyGate = makeIdentifyGate

--[[
	Asks Discord for the shard layout, starts every shard, and returns
	without waiting. Shared by `login` and `run`.

	Shard count comes from Discord unless overridden, along with the session
	start budget -- worth logging, because exhausting it locks the bot out for
	hours and the failure that follows looks nothing like its cause.
]]
local function connect(self: Client)
	if self.running then
		error("the client is already running", 3)
	end
	local info: typeof(self.api.gateway.getBot()) = startup(function()
		return self.api.gateway.getBot()
	end)
	local shardCount = self.options.shardCount or info.shards
	local limit = info.session_start_limit
	local maxConcurrency = limit.max_concurrency or 1
	Log.info(
		`gateway: {shardCount} shard(s), {limit.remaining}/{limit.total} session starts left, `
			.. `max concurrency {maxConcurrency}`
	)
	if limit.remaining < shardCount then
		error(
			`only {limit.remaining} gateway session starts remain but {shardCount} shards are needed; `
				.. `the budget resets in {math.floor(limit.reset_after / 1000)}s`,
			3
		)
	end

	local tuning: GatewayTuning = self.options.gateway or {}
	self.running = true
	self.startedAt = Util.now()
	self.shardCount = shardCount
	self.shards = {}
	self.fatalReason = nil
	self._readyShards = {}
	self._readyEmitted = false

	local gate, confirm = makeIdentifyGate(maxConcurrency, tuning.identifyInterval or 5.2)

	for shardId = 0, shardCount - 1 do
		local shard = Gateway.new({
			token = self.token,
			intents = self.intents,
			shardId = shardId,
			shardCount = shardCount,
			presence = self.options.presence,
			gatewayUrl = tuning.gatewayUrl or info.url,
			connect = tuning.connect,
			backoffBase = tuning.backoffBase,
			backoffCap = tuning.backoffCap,
			sendLimit = tuning.sendLimit,
			sendWindow = tuning.sendWindow,
			identifyGate = function(awake: () -> boolean)
				gate(shardId, awake)
			end,
			beforeIdentify = function(awake: () -> boolean)
				confirm(shardId, awake)
			end,
			onDispatch = function(event: string, data: any)
				onDispatch(self, shardId, event, data)
			end,
			onDisconnect = function(code: number?)
				Client.emit(self, "shardDisconnect", shardId, code)
			end,
			onFatal = function(reason: string)
				Log.error(`shard {shardId} gave up: {reason}`)
				-- One shard that cannot authenticate means none can; stop the
				-- rest rather than leaving them running behind a returned
				-- `run()`.
				self.fatalReason = reason
				Client.stop(self)
			end,
		})
		table.insert(self.shards, shard)
		task.spawn(function()
			Gateway.run(shard)
		end)
	end
end

--[[
	Connects and returns once every shard is READY (the moment `ready`
	fires), leaving the shards running in the background. Use this when the
	bot has its own main loop; `run` is `login` plus waiting until `stop`.

	Throws if a shard hits a fatal close code (bad token, disallowed
	intents) before that, with the reason Discord gave.
]]
function Client.login(self: Client)
	connect(self)
	while self.running and not self._readyEmitted do
		task.wait(0.02)
	end
	local reason = self.fatalReason
	if reason ~= nil then
		error(`could not connect: {reason}`, 2)
	end
end

--[[
	Connects and blocks until `stop` is called, then returns.

	If a shard gives up instead -- a fatal close such as 4004 (bad token) or
	4014 (disallowed intents) -- it raises `could not stay connected:
	<reason>`, as plain text, so a caller can tell the two endings apart.

	Note that Lute exits with status 0 for an error raised after the main
	thread has yielded, which `run` always has. A service whose supervisor
	reads the exit status should call it inside `Discord.main`, which exits
	1 on any error.
]]
function Client.run(self: Client)
	connect(self)
	-- Park the main thread. Everything real happens on scheduler tasks; this
	-- just keeps the process alive and gives `stop` something to end.
	while self.running do
		task.wait(0.05)
	end
	local reason = self.fatalReason
	if reason ~= nil then
		error(`could not stay connected: {reason}`, 0)
	end
	Log.info("client stopped")
end

--[[
	Closes every shard and makes `run` return. Heartbeat tasks end with
	their shards, so nothing the client started keeps the process alive.
	Safe to call more than once, and from inside a handler.
]]
function Client.stop(self: Client)
	if self.running then
		Log.info("shutting down")
	end
	for _, shard in self.shards do
		Gateway.stop(shard)
	end
	self.running = false
end

return Client
