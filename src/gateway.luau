--!strict
--[[
	One gateway shard: the WebSocket, the heartbeat, and the reconnect logic.

	The lifecycle Discord specifies, and which this implements:

	    HELLO (op 10)  -> start heartbeating at the interval it names
	    IDENTIFY (op 2) or RESUME (op 6)
	    READY / RESUMED -> dispatches start flowing
	    HEARTBEAT_ACK (op 11) must follow every heartbeat; if one does not,
	      the connection is a zombie -- it will sit there accepting nothing
	      forever -- and has to be torn down rather than waited on.

	Two details are easy to get wrong and expensive to debug:

	  * The first heartbeat is delayed by a RANDOM fraction of the interval.
	    Discord asks for this so that a fleet of shards reconnecting together
	    does not heartbeat in lockstep, and it is the difference between a
	    smooth restart and a wall of 429s.
	  * Resuming uses `resume_gateway_url` from READY, not the URL you first
	    dialled. Resuming against the wrong host silently starts a new session
	    and quietly drops every event that happened during the gap.

	Lute's WebSocket handle has no close-with-code, so a deliberate teardown
	cannot send 4000 ("I intend to resume"), and the close code we observe
	afterwards is whatever the runtime reports (1000, 1005, 1006, or none at
	all). The close code alone therefore cannot say whether to resume. When
	the shard closes a socket for a reason Discord says to resume after -- a
	RECONNECT, a missed HEARTBEAT_ACK, INVALID_SESSION with `d = true` -- it
	records that on the connection and resumes regardless of the code. If
	Discord read our close as session-ending, the RESUME comes back as
	INVALID_SESSION, the shard re-identifies, and only the gap is lost.

	Voice is not supported: `updateVoiceState` can move the bot in and out
	of a voice channel (for presence, or to vacate one), but there is no
	voice connection and no audio. That needs UDP and Opus, and Lute has
	neither.
]]
local netClient = require("@lute/net/client")
local task = require("@lute/task")

local Const = require("@discord/const")
local Json = require("@discord/json")
local Log = require("@discord/log")
local Types = require("@discord/types")
local Util = require("@discord/util")

local Gateway = {}
Gateway.__index = Gateway

--- The part of a WebSocket handle the shard uses. `@lute/net/client`'s
--- handle satisfies it, and so does the test suite's fake.
export type Socket = {
	send: (self: Socket, data: string) -> (),
	close: (self: Socket) -> (),
}

export type SocketHandlers = netClient.WebSocketOptions

--- Opens a socket. Defaults to `@lute/net/client`'s `websocket`.
export type Connect = (url: string, handlers: SocketHandlers) -> Socket

export type Options = {
	token: string,
	--- Decimal intents value.
	intents: number,
	shardId: number?,
	shardCount: number?,
	presence: Types.Presence?,
	largeThreshold: number?,
	--- Called for every DISPATCH: `(eventName, data)`.
	onDispatch: (string, any) -> (),
	--- Called when the shard becomes usable, and again after each resume.
	onConnected: ((resumed: boolean) -> ())?,
	--- Called each time a connection ends, with the close code if one was
	--- observed. Not called for the close `stop` causes.
	onDisconnect: ((code: number?) -> ())?,
	--- Called when the shard gives up for good.
	onFatal: ((reason: string) -> ())?,
	--[[
		Called, and allowed to yield, before every connection that will
		IDENTIFY (not before one that will RESUME). This is where the client
		enforces Discord's one-IDENTIFY-per-5s-per-bucket rule. It runs
		BEFORE dialling rather than after HELLO so a shard that is queued
		for its turn is not holding an open socket that has not
		authenticated -- Discord closes those.

		`awake` turns false once the shard is stopping. A gate that waits
		must wait in slices and return when it does: a Lute timer cannot be
		cancelled, so one long sleep would hold a stopped process open.
	]]
	identifyGate: ((awake: () -> boolean) -> ())?,
	--[[
		Called, and allowed to yield, immediately before IDENTIFY is sent.
		The dial-time gate spaces DIALS, but Discord counts IDENTIFYs, and a
		slow handshake on one shard followed by a fast one on the next can
		put two IDENTIFYs closer together than the dials were. This is where
		the client re-checks the spacing at the moment that counts. Heartbeats
		are already running by then, so a short wait here cannot zombie the
		socket. `awake` is as for `identifyGate`.
	]]
	beforeIdentify: ((awake: () -> boolean) -> ())?,
	--- Where to dial for a fresh session. Defaults to the public gateway;
	--- the client passes the `url` from GET /gateway/bot, as Discord asks.
	gatewayUrl: string?,
	--- The socket factory. Swapped by the test suite.
	connect: Connect?,
	--- Reconnect backoff: full jitter up to `min(cap, base * 2^attempt)`
	--- seconds. Defaults 1 and 60. The INVALID_SESSION pause (Discord asks
	--- for a random 1-5 s) is `base * (1 + 4 * random)`.
	backoffBase: number?,
	backoffCap: number?,
	--- The outgoing command budget. Discord allows 120 per 60 s per
	--- connection and closes the socket with 4008 past it. Defaults 110 and
	--- 60; the gap is headroom for heartbeats, which bypass the queue.
	sendLimit: number?,
	sendWindow: number?,
}

--[[
	One socket's worth of state.

	Everything that belongs to a single connection lives here rather than on
	the shard, because a closed socket's callbacks can still fire after the
	next one has opened -- a late `onclose` from the old socket would
	otherwise mark the NEW connection closed, and a stale heartbeat loop
	would beat on it.
]]
type Connection = {
	socket: Socket?,
	closed: boolean,
	closeCode: number?,
	heartbeat: thread?,
	awaitingAck: boolean,
	lastHeartbeat: Util.Instant?,
	--- We closed it ourselves, for a reason after which Discord says resume.
	resume: boolean,
	--- We closed it ourselves; the observed close code is not the server's.
	byUs: boolean,
	--- Reconnect without backoff (Discord asked us to, with op 7).
	immediate: boolean,
	--- An explicit pause before reconnecting (INVALID_SESSION).
	delay: number?,
	--- IDENTIFY or RESUME has gone out. Discord closes with 4003 on any
	--- other payload before that, so user commands wait for it.
	authenticated: boolean,
	--- The shard has read this connection's close code; later close
	--- callbacks (our own close echoed back) must not change it.
	reaped: boolean,
}

--- A user command held until the connection has authenticated.
type Pending = { op: number, d: any }

export type Gateway = typeof(setmetatable(
	{} :: {
		options: Options,
		socket: Socket?,
		state: string,
		sessionId: string?,
		resumeUrl: string?,
		sequence: number?,
		--- The presence to IDENTIFY with. Updated by `updatePresence`, so a
		--- re-identify does not revert the bot to its startup presence.
		presence: Types.Presence?,
		heartbeatInterval: number,
		lastHeartbeat: Util.Instant?,
		awaitingAck: boolean,
		latency: number,
		attempts: number,
		stopping: boolean,
		closed: boolean,
		closeCode: number?,
		--- Rolling window for the 120-commands-per-60s send limit.
		sendWindowStart: Util.Instant,
		sendCount: number,
		tag: string,
		_connection: Connection?,
		--- User commands waiting for IDENTIFY/RESUME, oldest first. Kept on
		--- the shard, not the connection, so a connection that dies before
		--- authenticating hands them to the next one.
		_pending: { Pending },
		--- The connection whose flush task is running, if any.
		_flushing: Connection?,
	},
	{} :: typeof(Gateway)
))

local DEFAULT_GATEWAY = "wss://gateway.discord.gg"
-- Discord's hard ceiling. Heartbeats, IDENTIFY and RESUME are never queued
-- behind user commands -- a heartbeat held back by a presence spam would
-- trip our own zombie detection -- but they still count, and they never
-- push the total past this.
local HARD_SEND_LIMIT = 120
local POLL = 0.02
-- Commands queued before authentication. Past this the shard refuses
-- rather than grows: a queue this deep means the caller is sending in a
-- loop against a shard that is not coming up.
local MAX_PENDING = 256

local function defaultConnect(url: string, handlers: SocketHandlers): Socket
	return (netClient.websocket(url, handlers) :: any) :: Socket
end

function Gateway.new(options: Options): Gateway
	local shardId = options.shardId or 0
	return setmetatable({
		options = options,
		socket = nil :: Socket?,
		state = "idle",
		sessionId = nil :: string?,
		resumeUrl = nil :: string?,
		sequence = nil :: number?,
		presence = options.presence,
		heartbeatInterval = 41.25,
		lastHeartbeat = nil :: Util.Instant?,
		awaitingAck = false,
		latency = 0,
		attempts = 0,
		stopping = false,
		closed = true,
		closeCode = nil :: number?,
		sendWindowStart = Util.now(),
		sendCount = 0,
		tag = `shard {shardId}`,
		_connection = nil :: Connection?,
		_pending = {},
		_flushing = nil :: Connection?,
	}, Gateway)
end

local function live(self: Gateway, conn: Connection): boolean
	return self._connection == conn and not conn.closed
end

--[[
	Sleeps up to `seconds` in short slices, returning early once `awake()`
	says stop.

	A single long `task.wait` cannot be cancelled: even closing the thread
	leaves its timer registered, and the timer alone keeps the process
	alive. A heartbeat parked in a 41 s wait would hold a stopped bot open
	for up to 41 s, so every long wait here is sliced.
]]
local function doze(seconds: number, awake: () -> boolean)
	local started = Util.now()
	while awake() do
		local left = seconds - Util.since(started)
		if left <= 0 then
			return
		end
		task.wait(math.min(0.1, left))
	end
end

--[[
	Puts one frame on the socket, within the send budget. Returns false,
	with no side effects, when the connection is gone or its socket does not
	exist yet: the shard publishes a connection before `websocket()` returns
	(it yields through the handshake), and treating that window as a failed
	send would close the very connection being opened.
]]
local function transmit(self: Gateway, conn: Connection, op: number, data: any, priority: boolean): boolean
	if conn.socket == nil then
		return false
	end
	local limit = self.options.sendLimit or 110
	local window = self.options.sendWindow or 60
	-- A loop, not one wait: several senders can be parked here together,
	-- and if each reset the window on waking they would all go at once.
	while true do
		if not live(self, conn) then
			return false
		end
		if Util.since(self.sendWindowStart) >= window then
			self.sendWindowStart = Util.now()
			self.sendCount = 0
		end
		local ceiling = if priority then HARD_SEND_LIMIT else limit
		if self.sendCount < ceiling then
			break
		end
		local wait = math.max(0.001, window - Util.since(self.sendWindowStart))
		Log.warn(`{self.tag}: gateway send budget exhausted, waiting {string.format("%.1f", wait)}s`)
		doze(wait, function(): boolean
			return live(self, conn)
		end)
	end
	local socket = conn.socket
	if socket == nil then
		return false
	end
	self.sendCount += 1
	local ok, err = pcall(function()
		socket:send(Json.encode({ op = op, d = data }))
	end)
	if not ok then
		Log.warn(`{self.tag}: send failed: {tostring(err)}`)
		conn.closed = true
		return false
	end
	return true
end

--[[
	Drains the pending queue onto an authenticated connection, in order and
	within the send budget. One flush task per connection; an entry leaves
	the queue only once it is on the wire, so a connection that dies
	mid-flush leaves the rest for the next one.
]]
local function flush(self: Gateway, conn: Connection)
	if self._flushing == conn or #self._pending == 0 then
		return
	end
	self._flushing = conn
	task.spawn(function()
		while #self._pending > 0 and conn.authenticated and live(self, conn) do
			local item = self._pending[1]
			if not transmit(self, conn, item.op, item.d, false) then
				break
			end
			if self._pending[1] == item then
				table.remove(self._pending, 1)
			end
		end
		if self._flushing == conn then
			self._flushing = nil
		end
	end)
end

--[[
	Sends a gateway command, respecting the 120-per-60s ceiling.

	Blowing that limit closes the socket with 4008 and, unlike a REST 429,
	there is no retry-after to obey -- you simply lose the connection. So a
	send over budget WAITS for the window to roll rather than going out.

	Before the connection has sent IDENTIFY or RESUME, Discord answers any
	command with 4003 and a closed socket. Such a send is QUEUED and goes
	out right after authentication, rather than dropped: `fetchMembers` is
	waiting on its op 8, and a presence change should not silently vanish
	because it raced a reconnect. Returns true once the command is sent or
	queued; false when there is no connection at all, or the queue is full.
]]
function Gateway.send(self: Gateway, op: number, data: any): boolean
	local conn = self._connection
	if conn == nil then
		return false
	end
	-- Anything behind a non-empty queue joins it, so commands keep their order.
	if not conn.authenticated or #self._pending > 0 then
		if #self._pending >= MAX_PENDING then
			Log.warn(`{self.tag}: {MAX_PENDING} commands already waiting for the connection; dropping op {op}`)
			return false
		end
		table.insert(self._pending, { op = op, d = data })
		if conn.authenticated then
			flush(self, conn)
		end
		return true
	end
	return transmit(self, conn, op, data, false)
end

--- Changes the bot's presence, and remembers it for the next IDENTIFY.
function Gateway.updatePresence(self: Gateway, presence: Types.Presence): boolean
	self.presence = presence
	return Gateway.send(self, Const.Op.PRESENCE_UPDATE, presence)
end

--[[
	Asks Discord to stream members for a guild (op 8). The answer arrives as
	GUILD_MEMBERS_CHUNK dispatches; `Client.fetchMembers` collects them.

	Needs the GUILD_MEMBERS privileged intent for anything but a lookup by
	`user_ids`. Discord requires either `query` or `user_ids`, so an empty
	request means "every member" (`query = ""`, `limit = 0`). The caller's
	table is copied, never modified.
]]
function Gateway.requestGuildMembers(self: Gateway, guildId: string, request: Types.MemberRequest?): boolean
	local payload: Types.MemberRequest = if request ~= nil then table.clone(request) else {}
	payload.guild_id = guildId
	if payload.user_ids == nil and payload.query == nil then
		payload.query = ""
	end
	if payload.query ~= nil and payload.limit == nil then
		payload.limit = 0
	end
	return Gateway.send(self, Const.Op.REQUEST_GUILD_MEMBERS, payload)
end

--[[
	Joins, moves between, or leaves (`channelId = nil`) a voice channel.

	This only changes the bot's voice STATE -- it shows up in the channel,
	muted or not. There is no audio: see the module comment. Leaving needs
	an explicit JSON `null` for `channel_id`; omitting the field is not the
	same thing and Discord rejects it.
]]
function Gateway.updateVoiceState(
	self: Gateway,
	guildId: string,
	channelId: string?,
	selfMute: boolean?,
	selfDeaf: boolean?
): boolean
	return Gateway.send(self, Const.Op.VOICE_STATE_UPDATE, {
		guild_id = guildId,
		channel_id = if channelId ~= nil then channelId else Json.null,
		self_mute = selfMute == true,
		self_deaf = selfDeaf == true,
	})
end

local function canResume(self: Gateway): boolean
	return self.sessionId ~= nil and self.sequence ~= nil
end

local function identify(self: Gateway, conn: Connection)
	local options = self.options
	local shardId = options.shardId or 0
	local beforeIdentify = options.beforeIdentify
	if beforeIdentify ~= nil then
		beforeIdentify(function(): boolean
			return live(self, conn) and not self.stopping
		end)
		if not live(self, conn) or self.stopping then
			return
		end
	end
	-- IDENTIFY carries the current presence, so queued presence updates are
	-- already said; sending them again only spends the budget.
	local kept = {}
	for _, item in self._pending do
		if item.op ~= Const.Op.PRESENCE_UPDATE then
			table.insert(kept, item)
		end
	end
	self._pending = kept
	Log.info(`{self.tag}: identifying`)
	local sent = transmit(self, conn, Const.Op.IDENTIFY, {
		token = options.token,
		intents = options.intents,
		large_threshold = options.largeThreshold or 250,
		presence = self.presence,
		shard = { shardId, options.shardCount or 1 },
		properties = {
			os = "linux",
			browser = "lute-discord",
			device = "lute-discord",
		},
	}, true)
	if sent then
		conn.authenticated = true
		flush(self, conn)
	end
end

local function resume(self: Gateway, conn: Connection)
	Log.info(`{self.tag}: resuming session {tostring(self.sessionId)} at sequence {tostring(self.sequence)}`)
	local sent = transmit(self, conn, Const.Op.RESUME, {
		token = self.options.token,
		session_id = self.sessionId,
		seq = self.sequence,
	}, true)
	if sent then
		conn.authenticated = true
		flush(self, conn)
	end
end

local function stopHeartbeat(conn: Connection)
	local thread = conn.heartbeat
	conn.heartbeat = nil
	-- A thread cannot close itself; when the heartbeat loop is the one
	-- tearing down, it returns on its own right after.
	if thread ~= nil and thread ~= coroutine.running() and coroutine.status(thread) == "suspended" then
		-- Closed rather than left to notice on its next slice, so no beat
		-- can go out on a connection we have already given up on.
		coroutine.close(thread)
	end
end

--- Closes a connection from our side. `resume` records that Discord's
--- protocol says to RESUME afterwards; see the module comment.
local function teardown(self: Gateway, conn: Connection, resume: boolean, why: string)
	if conn.closed and conn.socket == nil then
		return
	end
	Log.info(`{self.tag}: closing connection ({why})`)
	conn.byUs = true
	conn.resume = conn.resume or resume
	conn.closed = true
	stopHeartbeat(conn)
	local socket = conn.socket
	if socket ~= nil then
		pcall(function()
			socket:close()
		end)
	end
end

--[[
	The heartbeat loop, one per connection.

	It exits as soon as the connection it was started for is gone, so a
	reconnect never ends up with two loops sharing one socket -- which reads
	to Discord as double the heartbeat rate and burns the send budget.
]]
local function startHeartbeat(self: Gateway, conn: Connection)
	stopHeartbeat(conn)
	conn.heartbeat = task.spawn(function()
		local function awake(): boolean
			return live(self, conn)
		end
		-- Jittered first beat: see the module comment.
		doze(self.heartbeatInterval * math.random(), awake)
		while live(self, conn) do
			if conn.awaitingAck then
				-- No ACK since the last beat: the socket is a zombie. Discord
				-- says to reconnect and resume.
				Log.warn(`{self.tag}: heartbeat not acknowledged, reconnecting`)
				teardown(self, conn, true, "zombie connection")
				return
			end
			conn.awaitingAck = true
			conn.lastHeartbeat = Util.now()
			self.awaitingAck = true
			self.lastHeartbeat = conn.lastHeartbeat
			if not transmit(self, conn, Const.Op.HEARTBEAT, self.sequence, true) then
				return
			end
			doze(self.heartbeatInterval, awake)
		end
	end)
end

local function handlePayload(self: Gateway, conn: Connection, raw: string)
	local payload, err = Json.decode(raw)
	if type(payload) ~= "table" then
		Log.warn(`{self.tag}: undecodable frame: {tostring(err)}`)
		return
	end

	local op = payload.op
	if op == Const.Op.DISPATCH then
		if type(payload.s) == "number" then
			self.sequence = payload.s
		end
		local event = payload.t
		local data = payload.d
		if event == "READY" and type(data) == "table" then
			self.sessionId = data.session_id
			self.resumeUrl = data.resume_gateway_url
			self.attempts = 0
			self.state = "ready"
			local who: any = data.user
			local user = if type(who) == "table" then who.username else "?"
			local guilds = if type(data.guilds) == "table" then #data.guilds else 0
			Log.info(`{self.tag}: ready as {tostring(user)} in {guilds} guild(s)`)
			local onConnected = self.options.onConnected
			if onConnected ~= nil then
				pcall(onConnected, false)
			end
		elseif event == "RESUMED" then
			self.attempts = 0
			self.state = "ready"
			Log.info(`{self.tag}: resumed`)
			local onConnected = self.options.onConnected
			if onConnected ~= nil then
				pcall(onConnected, true)
			end
		end
		-- Handlers are user code; one that throws must not take the socket
		-- with it, and the traceback has to name the handler, not this line.
		local ok, handlerError = xpcall(function(): boolean
			self.options.onDispatch(event, data)
			return true
		end, function(message: any): string
			return debug.traceback(tostring(message), 2)
		end)
		if not ok then
			Log.error(`{self.tag}: handler for {tostring(event)} failed:\n{tostring(handlerError)}`)
		end
	elseif op == Const.Op.HELLO then
		local hello: any = payload.d
		local interval = if type(hello) == "table" then tonumber(hello.heartbeat_interval) else nil
		self.heartbeatInterval = (interval or 41250) / 1000
		-- `websocket()` yields through the handshake and HELLO can be
		-- delivered before it has handed back the socket; nothing can be
		-- sent until it has.
		while conn.socket == nil and live(self, conn) do
			task.wait(0.005)
		end
		if not live(self, conn) then
			return
		end
		conn.awaitingAck = false
		self.awaitingAck = false
		startHeartbeat(self, conn)
		if canResume(self) then
			resume(self, conn)
		else
			-- On its own task: `beforeIdentify` may wait for the IDENTIFY
			-- slot, and holding the message callback that long would stall
			-- every frame behind HELLO, heartbeat ACKs included. `spawn` runs
			-- it at once, so without a wait IDENTIFY still goes out inline.
			task.spawn(identify, self, conn)
		end
	elseif op == Const.Op.HEARTBEAT_ACK then
		conn.awaitingAck = false
		self.awaitingAck = false
		local mark = conn.lastHeartbeat
		if mark ~= nil then
			self.latency = Util.since(mark)
		end
	elseif op == Const.Op.HEARTBEAT then
		-- Discord can ask for one out of band; answer immediately, without
		-- waiting for the scheduled beat.
		conn.awaitingAck = true
		conn.lastHeartbeat = Util.now()
		transmit(self, conn, Const.Op.HEARTBEAT, self.sequence, true)
	elseif op == Const.Op.RECONNECT then
		-- Discord is moving us (a deploy, a rebalance). Resume straight away;
		-- backing off here only widens the gap of missed events.
		conn.immediate = true
		teardown(self, conn, true, "server requested reconnect")
	elseif op == Const.Op.INVALID_SESSION then
		-- `d` is whether the session may still be resumed. Either way
		-- Discord asks for a random 1-5 s pause first; reconnecting at once
		-- is how a fleet of shards turns one invalidation into a storm.
		local resumable = payload.d == true
		if not resumable then
			Log.warn(`{self.tag}: session invalidated, will start a new one`)
			self.sessionId = nil
			self.sequence = nil
		end
		conn.delay = (self.options.backoffBase or 1) * (1 + 4 * math.random())
		teardown(self, conn, resumable, "invalid session")
	end
end

--- Opens one connection and returns it once it has closed.
local function runConnection(self: Gateway): Connection
	local base = if canResume(self) and self.resumeUrl ~= nil
		then self.resumeUrl :: string
		else self.options.gatewayUrl or DEFAULT_GATEWAY
	base = string.gsub(base, "/+$", "")
	local url = base .. Const.GATEWAY_QUERY

	local conn: Connection = {
		socket = nil,
		closed = false,
		closeCode = nil,
		heartbeat = nil,
		awaitingAck = false,
		lastHeartbeat = nil,
		resume = false,
		byUs = false,
		immediate = false,
		delay = nil,
		authenticated = false,
		reaped = false,
	}
	self._connection = conn
	self.closed = false
	self.closeCode = nil
	self.awaitingAck = false
	-- The send budget is per connection.
	self.sendWindowStart = Util.now()
	self.sendCount = 0
	self.state = "connecting"

	local handlers: SocketHandlers = {
		onmessage = function(message: string | buffer)
			-- A socket we already closed can still deliver; ignore it.
			if not live(self, conn) then
				return
			end
			local text = if type(message) == "string" then message else buffer.tostring(message)
			handlePayload(self, conn, text)
		end,
		onclose = function(code: number, reason: string)
			if self._connection == conn and not conn.byUs then
				Log.info(`{self.tag}: socket closed ({code}{if reason ~= "" then " " .. reason else ""})`)
			end
			if conn.closeCode == nil and not conn.reaped then
				conn.closeCode = code
			end
			conn.closed = true
		end,
		onerror = function(message: string)
			if self._connection == conn and not conn.byUs then
				Log.warn(`{self.tag}: socket error: {message}`)
			end
			conn.closed = true
		end,
	}
	local connect: Connect = self.options.connect or defaultConnect
	local ok, socket = pcall(connect, url, handlers)
	if not ok then
		Log.warn(`{self.tag}: could not open socket: {tostring(socket)}`)
		conn.closed = true
	else
		conn.socket = socket
		self.socket = socket

		-- Nothing here is event-driven at the top level, so the shard parks
		-- on a poll until its socket reports closed.
		while not conn.closed and not self.stopping do
			task.wait(POLL)
		end

		-- A server close can surface as `onerror` just before `onclose`.
		-- Deciding on the missing code would treat a fatal 4004 as "retry",
		-- which is the auth-failure loop that gets a token flagged -- so give
		-- the code a moment to arrive.
		if not conn.byUs and not self.stopping and conn.closeCode == nil then
			local waited = 0
			while conn.closeCode == nil and waited < 0.5 do
				task.wait(POLL)
				waited += POLL
			end
		end

		-- Every path out of the loop closes the handle, including a
		-- connection that was marked dead while the dial was still yielding
		-- and one whose send failed: nothing else will. The code is settled
		-- first so the runtime's echo of our own close cannot stand in for
		-- the server's verdict.
		conn.reaped = true
		pcall(function()
			socket:close()
		end)
	end
	conn.reaped = true

	if self.stopping then
		teardown(self, conn, false, "stopping")
	end
	stopHeartbeat(conn)
	conn.closed = true
	if self._connection == conn then
		self._connection = nil
		self.socket = nil
		self.closed = true
		self.closeCode = conn.closeCode
	end
	self.state = "disconnected"
	return conn
end

--- Sleeps, but wakes early once `stop` is called, so `stop` never waits out
--- a 60 s backoff.
local function nap(self: Gateway, seconds: number)
	doze(seconds, function(): boolean
		return not self.stopping
	end)
end

--[[
	Runs the shard until `stop` is called or something unrecoverable happens.

	A close code that Discord says is fatal (bad token, intents you were not
	granted, an impossible shard configuration) ends the loop rather than
	looping forever -- retrying those is how a token gets flagged.
]]
function Gateway.run(self: Gateway)
	local options = self.options
	while not self.stopping do
		local gate = options.identifyGate
		if gate ~= nil and not canResume(self) then
			gate(function(): boolean
				return not self.stopping
			end)
			if self.stopping then
				break
			end
		end

		local conn = runConnection(self)
		if self.stopping then
			break
		end

		local code = conn.closeCode
		local onDisconnect = options.onDisconnect
		if onDisconnect ~= nil then
			pcall(onDisconnect, code)
		end

		local fatal = if code ~= nil and not conn.byUs then Const.FATAL_CLOSE_CODES[code] else nil
		if fatal ~= nil then
			Log.error(`{self.tag}: {fatal} (close code {code})`)
			self.state = "fatal"
			self.stopping = true
			local onFatal = options.onFatal
			if onFatal ~= nil then
				pcall(onFatal, fatal)
			end
			return
		end

		-- Discord says to resume after a disconnect with no close code or
		-- with one that allows reconnecting, and to start over only after
		-- 4007, 4009, or a server 1000/1001. 1005 and 1006 are the runtime
		-- reporting that no close frame arrived at all -- the common network
		-- blip -- so they resume. When we closed the socket ourselves the
		-- observed code is our own close echoed back, not a verdict on the
		-- session: the reason we closed already decided (INVALID_SESSION
		-- d=false cleared the session; RECONNECT and a zombie keep it).
		if not conn.byUs and code ~= nil and Const.SESSION_ENDING_CLOSE_CODES[code] then
			self.sessionId = nil
			self.sequence = nil
		end

		local delay: number
		if conn.immediate then
			delay = 0
		elseif conn.delay ~= nil then
			delay = conn.delay :: number
		else
			self.attempts += 1
			delay = Util.backoff(self.attempts, options.backoffBase or 1, options.backoffCap or 60)
		end
		Log.info(`{self.tag}: reconnecting in {string.format("%.1f", delay)}s (attempt {self.attempts})`)
		nap(self, delay)
	end
	self.state = "stopped"
	Log.info(`{self.tag}: stopped`)
end

--- Closes the socket and ends `run`. The heartbeat task ends with it.
function Gateway.stop(self: Gateway)
	self.stopping = true
	self.closed = true
	self._pending = {}
	local conn = self._connection
	if conn ~= nil then
		teardown(self, conn, false, "stopping")
	end
end

return Gateway
