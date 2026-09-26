--!strict
--[[
	One gateway shard, end to end against a fake socket: HELLO, IDENTIFY,
	heartbeats, READY, resume, the close-code rules and the send budget.

	Discord's intervals are shrunk to tens of milliseconds and every timing
	assertion carries slack; what is being tested is order and rules, not a
	stopwatch.
]]
local task = require("@lute/task")

local Const = require("@discord/const")
local Gateway = require("@discord/gateway")
local Log = require("@discord/log")
local Fakes = require("./fakes")
local h = require("./harness")

Log.setLevel("error")

local Op = Const.Op
local GATEWAY = "wss://gateway.discord.test"
local RESUME_URL = "wss://resume.discord.test"
local QUERY = Const.GATEWAY_QUERY

type Harness = {
	gw: Gateway.Gateway,
	conn: Fakes.Connector,
	events: { { event: string, data: any } },
	connected: { boolean },
	disconnects: { number },
	fatal: string?,
	gateCalls: number,
	finished: boolean,
	socket: (self: Harness, index: number) -> Fakes.FakeSocket,
}

local function start(overrides: { [string]: any }?): Harness
	local conn = Fakes.connector()
	local self = {
		conn = conn,
		events = {},
		connected = {},
		disconnects = {},
		fatal = nil :: string?,
		gateCalls = 0,
		finished = false,
	} :: Harness

	local options: Gateway.Options = {
		token = "TOKEN",
		intents = 513,
		shardId = 1,
		shardCount = 2,
		presence = { status = "idle", activities = {}, afk = false, since = 0 },
		gatewayUrl = GATEWAY,
		connect = conn.connect,
		backoffBase = 0.005,
		backoffCap = 0.01,
		onDispatch = function(event: string, data: any)
			table.insert(self.events, { event = event, data = data })
			if event == "BOOM" then
				error("handler exploded")
			end
		end,
		onConnected = function(resumed: boolean)
			table.insert(self.connected, resumed)
		end,
		onDisconnect = function(code: number?)
			table.insert(self.disconnects, code or -1)
		end,
		onFatal = function(reason: string)
			self.fatal = reason
		end,
		identifyGate = function()
			self.gateCalls += 1
		end,
	}
	for key, value in overrides or {} do
		(options :: any)[key] = value
	end
	self.gw = Gateway.new(options)

	function self.socket(harness: Harness, index: number): Fakes.FakeSocket
		Fakes.waitUntil(function()
			return #harness.conn.sockets >= index
		end)
		local socket = harness.conn.sockets[index]
		assert(socket ~= nil, `socket {index} never opened`)
		return socket
	end

	task.spawn(function()
		Gateway.run(self.gw)
		self.finished = true
	end)
	return self
end

local function stop(harness: Harness)
	Gateway.stop(harness.gw)
	Fakes.waitUntil(function()
		return harness.finished
	end)
end

--- HELLO with a long interval (no heartbeat noise), then READY.
local function connectReady(harness: Harness, index: number, session: string): Fakes.FakeSocket
	local socket = harness:socket(index)
	socket:hello(60000)
	socket:dispatch("READY", Fakes.ready(session, RESUME_URL), 1)
	return socket
end

----------------------------------------------------------------------------
-- HELLO -> IDENTIFY, and heartbeats with a jittered first beat
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = harness:socket(1)
	h.equals("dials the gateway URL with version and encoding", socket.url, GATEWAY .. QUERY)
	h.equals("the identify gate ran before dialling a fresh session", harness.gateCalls, 1)

	local helloAt = Fakes.clock()
	socket:hello(100)
	local identify = socket:ofOp(Op.IDENTIFY)[1]
	h.check("IDENTIFY is sent in reply to HELLO", identify ~= nil)
	local d = identify.d
	h.equals("IDENTIFY carries the token", d.token, "TOKEN")
	h.equals("IDENTIFY carries the intents", d.intents, 513)
	h.check("IDENTIFY carries [shardId, shardCount]", d.shard[1] == 1 and d.shard[2] == 2)
	h.equals("IDENTIFY carries connection properties", d.properties.browser, "lute-discord")
	h.equals("IDENTIFY carries the presence", d.presence.status, "idle")
	h.equals("no heartbeat is sent synchronously with HELLO", #socket:ofOp(Op.HEARTBEAT), 0)

	-- Ack every beat so the connection stays healthy.
	local acked = 0
	task.spawn(function()
		while not harness.finished do
			local beats = #socket:ofOp(Op.HEARTBEAT)
			if beats > acked then
				acked = beats
				socket:push({ op = Op.HEARTBEAT_ACK })
			end
			task.wait(0.002)
		end
	end)

	h.check("heartbeats start", Fakes.waitUntil(function()
		return #socket:ofOp(Op.HEARTBEAT) >= 2
	end, 1))
	local beats = socket:ofOp(Op.HEARTBEAT)
	local first = beats[1].at - helloAt
	h.check(`first beat lands within one interval (after {string.format("%.3f", first)}s)`, first <= 0.1 + 0.03)
	local gap = beats[2].at - beats[1].at
	h.check(`later beats follow the interval (gap {string.format("%.3f", gap)}s)`, gap >= 0.1 - 0.01)
	h.equals("heartbeat carries the last sequence (none yet)", beats[1].d, nil)
	h.check("acked heartbeats keep the socket open", not socket.closedByClient)
	h.check("latency was measured", harness.gw.latency >= 0)

	-- Out-of-band HEARTBEAT request: answered at once.
	local before = #socket:ofOp(Op.HEARTBEAT)
	socket:push({ op = Op.HEARTBEAT })
	h.equals("op 1 from the server gets an immediate heartbeat", #socket:ofOp(Op.HEARTBEAT), before + 1)

	-- READY
	socket:dispatch("READY", Fakes.ready("sess-1", RESUME_URL), 1)
	h.equals("READY stores the session id", harness.gw.sessionId, "sess-1")
	h.equals("READY stores resume_gateway_url", harness.gw.resumeUrl, RESUME_URL)
	h.equals("READY stores the sequence", harness.gw.sequence, 1)
	h.equals("onConnected(false) after READY", harness.connected[1], false)
	h.equals("READY is dispatched to the handler too", harness.events[1].event, "READY")

	-- A throwing handler must not take the shard down.
	socket:dispatch("BOOM", {}, 2)
	socket:dispatch("AFTER", { ok = true }, 3)
	h.equals("a dispatch after a throwing handler still arrives", harness.events[#harness.events].event, "AFTER")
	h.equals("sequence kept advancing past the throw", harness.gw.sequence, 3)
	h.check("the socket survived the throw", not socket.closedByClient)

	-- stop() ends run() and the heartbeat loop.
	stop(harness)
	h.check("stop() makes run() return", harness.finished)
	h.check("stop() closed the socket", socket.closedByClient)
	local after = #socket:ofOp(Op.HEARTBEAT)
	task.wait(0.25)
	h.equals("no heartbeats after stop", #socket:ofOp(Op.HEARTBEAT), after)
	h.equals("no reconnect after stop", #harness.conn.sockets, 1)
end

----------------------------------------------------------------------------
-- Missed ACK: zombie torn down, then RESUMED on the resume URL
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = harness:socket(1)
	socket:hello(40)
	socket:dispatch("READY", Fakes.ready("sess-z", RESUME_URL), 1)
	socket:dispatch("MESSAGE_CREATE", { id = "m" }, 2)
	-- Never ACK.
	h.check("an unacknowledged heartbeat closes the socket", Fakes.waitUntil(function()
		return socket.closedByClient
	end, 1))
	h.check("at least one beat went out before giving up", #socket:ofOp(Op.HEARTBEAT) >= 1)

	local second = harness:socket(2)
	h.equals("the zombie reconnect dials resume_gateway_url", second.url, RESUME_URL .. QUERY)
	h.equals("resume does not pass through the identify gate", harness.gateCalls, 1)
	second:hello(60000)
	local resume = second:ofOp(Op.RESUME)[1]
	h.check("RESUME sent instead of IDENTIFY", resume ~= nil and #second:ofOp(Op.IDENTIFY) == 0)
	h.equals("RESUME carries the session", resume and resume.d.session_id, "sess-z")
	h.equals("RESUME carries the last sequence", resume and resume.d.seq, 2)
	h.equals("RESUME carries the token", resume and resume.d.token, "TOKEN")

	second:dispatch("RESUMED", {}, 3)
	h.equals("onConnected(true) after RESUMED", harness.connected[#harness.connected], true)
	-- The first socket's late close echo (1000) must not be read as the
	-- new connection closing, nor as "session over".
	task.wait(0.05)
	h.check("the old socket's late close did not close the new one", not second.closedByClient and harness.gw.socket ~= nil)
	h.equals("session survived our own close", harness.gw.sessionId, "sess-z")
	stop(harness)
end

----------------------------------------------------------------------------
-- Resumable server close
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-r")
	socket:dispatch("GUILD_CREATE", { id = "g" }, 2)
	socket:dispatch("MESSAGE_CREATE", { id = "m" }, 3)
	socket:serverClose(4000, "unknown error")
	local second = harness:socket(2)
	h.equals("resumable close dials the resume URL", second.url, RESUME_URL .. QUERY)
	second:hello(60000)
	local resume = second:ofOp(Op.RESUME)[1]
	h.equals("and resumes at the last sequence", resume and resume.d.seq, 3)
	h.equals("onDisconnect saw the close code", harness.disconnects[1], 4000)
	stop(harness)
end

----------------------------------------------------------------------------
-- 4007 / non-resumable close: session dropped, fresh IDENTIFY
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-n")
	socket:serverClose(4007, "invalid seq")
	local second = harness:socket(2)
	h.equals("4007 means a new session: dial the main gateway", second.url, GATEWAY .. QUERY)
	h.equals("session cleared", harness.gw.sessionId, nil)
	h.equals("a fresh identify passes through the gate again", harness.gateCalls, 2)
	second:hello(60000)
	h.equals("IDENTIFY, not RESUME", #second:ofOp(Op.IDENTIFY), 1)
	h.equals("no RESUME", #second:ofOp(Op.RESUME), 0)

	second:dispatch("READY", Fakes.ready("sess-n2", RESUME_URL), 1)
	second:serverClose(1000, "")
	local third = harness:socket(3)
	h.equals("a server 1000 also ends the session", third.url, GATEWAY .. QUERY)
	stop(harness)
end

----------------------------------------------------------------------------
-- INVALID_SESSION
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-i")
	socket:push({ op = Op.INVALID_SESSION, d = false })
	h.check("INVALID_SESSION closes the socket", socket.closedByClient)
	h.equals("d=false clears the session", harness.gw.sessionId, nil)
	local second = harness:socket(2)
	h.equals("d=false reconnects to the main gateway", second.url, GATEWAY .. QUERY)
	second:hello(60000)
	h.equals("d=false re-identifies", #second:ofOp(Op.IDENTIFY), 1)

	second:dispatch("READY", Fakes.ready("sess-i2", RESUME_URL), 1)
	second:dispatch("TYPING_START", {}, 2)
	second:push({ op = Op.INVALID_SESSION, d = true })
	local third = harness:socket(3)
	h.equals("d=true keeps the session", harness.gw.sessionId, "sess-i2")
	h.equals("d=true reconnects to the resume URL", third.url, RESUME_URL .. QUERY)
	third:hello(60000)
	local resume = third:ofOp(Op.RESUME)[1]
	h.equals("d=true resumes at the last sequence", resume and resume.d.seq, 2)
	stop(harness)
end

----------------------------------------------------------------------------
-- RECONNECT (op 7)
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-7")
	socket:dispatch("MESSAGE_CREATE", {}, 2)
	local askedAt = Fakes.clock()
	socket:push({ op = Op.RECONNECT })
	h.check("op 7 closes the socket", socket.closedByClient)
	local second = harness:socket(2)
	h.check("and reconnects without backing off", Fakes.clock() - askedAt < 0.1)
	h.equals("to the resume URL", second.url, RESUME_URL .. QUERY)
	second:hello(60000)
	h.equals("with a RESUME", #second:ofOp(Op.RESUME), 1)
	h.equals("even though our own close was observed as 1000", harness.gw.sessionId, "sess-7")
	stop(harness)
end

----------------------------------------------------------------------------
-- Fatal close codes stop the loop
----------------------------------------------------------------------------
for _, code in { 4004, 4014 } do
	local harness = start()
	local socket = harness:socket(1)
	socket:hello(60000)
	socket:serverClose(code, "nope")
	h.check(`close {code} ends run()`, Fakes.waitUntil(function()
		return harness.finished
	end, 1))
	h.check(`close {code} calls onFatal`, harness.fatal ~= nil and harness.fatal == Const.FATAL_CLOSE_CODES[code])
	task.wait(0.05)
	h.equals(`close {code} does not reconnect`, #harness.conn.sockets, 1)
end

-- onerror arriving just before onclose must not lose the fatal code.
do
	local harness = start()
	local socket = harness:socket(1)
	socket:hello(60000)
	local onerror = socket.handlers.onerror :: (string) -> ()
	local onclose = socket.handlers.onclose :: (number, string) -> ()
	onerror("stream reset")
	task.defer(onclose, 4004, "Authentication failed.")
	h.check("a 4004 that trails an error is still fatal", Fakes.waitUntil(function()
		return harness.finished and harness.fatal ~= nil
	end, 1))
	h.equals("and there was no retry", #harness.conn.sockets, 1)
end

----------------------------------------------------------------------------
-- Connect failures back off and retry
----------------------------------------------------------------------------
do
	local harness = start()
	-- `run` dials as soon as it starts, so let that one succeed and drop,
	-- then refuse the next two.
	local socket = harness:socket(1)
	harness.conn.failNext = 2
	socket:serverClose(1006, "")
	local next = harness:socket(2)
	h.check("after two refused connects the shard dials again", next ~= nil)
	h.check("attempts counted", harness.gw.attempts >= 3)
	stop(harness)
end

----------------------------------------------------------------------------
-- Send budget: waits instead of going over; heartbeats bypass the queue
----------------------------------------------------------------------------
do
	local harness = start({ sendLimit = 3, sendWindow = 0.2 })
	local socket = harness:socket(1)
	local openedAt = Fakes.clock()
	socket:hello(60000) -- IDENTIFY: 1 of 3
	local done = 0
	for index = 1, 3 do
		task.spawn(function()
			Gateway.updatePresence(harness.gw, { status = "dnd", activities = {}, afk = false, since = index })
			done += 1
		end)
	end
	h.equals("two presence updates fit in the budget at once", #socket:ofOp(Op.PRESENCE_UPDATE), 2)
	-- Budget exhausted, but a server heartbeat request must still be answered.
	socket:push({ op = Op.HEARTBEAT })
	h.equals("a heartbeat is never queued behind the budget", #socket:ofOp(Op.HEARTBEAT), 1)
	Fakes.waitUntil(function()
		return done == 3
	end, 1)
	local updates = socket:ofOp(Op.PRESENCE_UPDATE)
	h.equals("the third update was sent eventually", #updates, 3)
	h.check(
		`the third update waited for the window to roll ({string.format("%.3f", updates[3].at - openedAt)}s)`,
		updates[3] ~= nil and updates[3].at - openedAt >= 0.2 - 0.03
	)
	stop(harness)
end

----------------------------------------------------------------------------
-- Presence survives a re-identify; op 8 and op 4 payloads
----------------------------------------------------------------------------
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-p")
	Gateway.updatePresence(harness.gw, { status = "dnd", activities = {}, afk = false, since = 0 })
	socket:push({ op = Op.INVALID_SESSION, d = false })
	local second = harness:socket(2)
	second:hello(60000)
	local identify = second:ofOp(Op.IDENTIFY)[1]
	h.equals("re-identify uses the latest presence, not the startup one", identify and identify.d.presence.status, "dnd")

	local request = { query = "to", limit = 5 }
	Gateway.requestGuildMembers(harness.gw, "123456789012345678", request :: any)
	local op8 = second:ofOp(Op.REQUEST_GUILD_MEMBERS)[1]
	h.equals("op 8 carries the guild id", op8 and op8.d.guild_id, "123456789012345678")
	h.equals("op 8 carries the query", op8 and op8.d.query, "to")
	h.equals("the caller's table was not modified", (request :: any).guild_id, nil)
	Gateway.requestGuildMembers(harness.gw, "123456789012345678")
	local all = second:ofOp(Op.REQUEST_GUILD_MEMBERS)[2]
	h.check("an empty request asks for everyone", all ~= nil and all.d.query == "" and all.d.limit == 0)

	Gateway.updateVoiceState(harness.gw, "123456789012345678", "223456789012345678", true, false)
	Gateway.updateVoiceState(harness.gw, "123456789012345678", nil)
	local voice = second:ofOp(Op.VOICE_STATE_UPDATE)
	h.equals("op 4 joins a channel", voice[1] and voice[1].d.channel_id, "223456789012345678")
	h.equals("op 4 carries self_mute", voice[1] and voice[1].d.self_mute, true)
	-- Json.decode flattens null to nil, so check the raw frame instead.
	h.check("op 4 leaves with an explicit null channel", voice[2] ~= nil and voice[2].d.channel_id == nil and voice[2].d.guild_id ~= nil)
	stop(harness)
end

----------------------------------------------------------------------------
-- Sending while the socket is still dialling
----------------------------------------------------------------------------
-- Lute's `websocket()` yields through the handshake, and the shard has
-- already published the connection by then. A send in that window must not
-- kill the connection it is waiting for.
do
	local conn = Fakes.connector()
	conn.dialDelay = 0.05
	local harness = start({ connect = conn.connect })
	harness.conn = conn
	local socket = harness:socket(1)
	h.check("the fake is still dialling", not socket.dialled)
	local accepted = Gateway.updatePresence(harness.gw, { status = "dnd", activities = {}, afk = false, since = 0 })
	h.check("a send during the dial is accepted for later", accepted)
	h.equals("and nothing reached the socket yet", #socket.sent, 0)
	Fakes.waitUntil(function()
		return socket.dialled
	end)
	socket:hello(60000)
	h.equals("HELLO after the dial still gets an IDENTIFY", #socket:ofOp(Op.IDENTIFY), 1)
	h.check("the connection survived the early send", not socket.closedByClient and #harness.conn.sockets == 1)
	stop(harness)
end

-- HELLO can arrive before `websocket()` has returned the handle.
do
	local conn = Fakes.connector()
	conn.dialDelay = 0.05
	local harness = start({ connect = conn.connect })
	harness.conn = conn
	local socket = harness:socket(1)
	socket:hello(60000)
	h.equals("a HELLO delivered mid-dial is answered once the handle exists", #socket:ofOp(Op.IDENTIFY), 1)
	h.check("and the IDENTIFY went out after the dial finished", socket.dialled)
	stop(harness)
end

-- A connection that dies during the dial must not leak its socket.
do
	local conn = Fakes.connector()
	conn.dialDelay = 0.05
	conn.closeEcho = nil
	local harness = start({ connect = conn.connect })
	harness.conn = conn
	local socket = harness:socket(1)
	local onerror = socket.handlers.onerror :: (string) -> ()
	onerror("handshake reset")
	h.check("a socket whose connection died mid-dial is closed, not leaked", Fakes.waitUntil(function()
		return socket.closedByClient
	end, 1))
	stop(harness)
end

----------------------------------------------------------------------------
-- User commands wait for IDENTIFY / RESUME
----------------------------------------------------------------------------
-- Discord closes with 4003 on any payload before the connection has
-- authenticated. Commands sent in that window are queued and flushed right
-- after IDENTIFY or RESUME.
do
	local harness = start()
	local socket = harness:socket(1)
	h.check("presence before HELLO is accepted", Gateway.updatePresence(harness.gw, { status = "dnd", activities = {}, afk = false, since = 0 }))
	h.check("op 8 before HELLO is accepted", Gateway.requestGuildMembers(harness.gw, "123456789012345678"))
	h.check("op 4 before HELLO is accepted", Gateway.updateVoiceState(harness.gw, "123456789012345678", nil))
	h.equals("nothing is sent before authenticating", #socket.sent, 0)
	socket:hello(60000)
	local ops = {}
	for _, frame in socket.sent do
		table.insert(ops, frame.op)
	end
	h.equals("IDENTIFY is the first frame", ops[1], Op.IDENTIFY)
	h.equals("the queued op 8 follows it", ops[2], Op.REQUEST_GUILD_MEMBERS)
	h.equals("then the queued op 4, in order", ops[3], Op.VOICE_STATE_UPDATE)
	h.equals("the queued presence was folded into IDENTIFY instead of resent", #socket:ofOp(Op.PRESENCE_UPDATE), 0)
	h.equals("IDENTIFY carries that presence", socket:ofOp(Op.IDENTIFY)[1].d.presence.status, "dnd")

	-- On a RESUME the presence is not part of the handshake, so it is sent.
	socket:dispatch("READY", Fakes.ready("sess-q", RESUME_URL), 1)
	socket:serverClose(4000, "")
	local second = harness:socket(2)
	Gateway.updatePresence(harness.gw, { status = "idle", activities = {}, afk = false, since = 0 })
	h.equals("nothing is sent on the new socket before RESUME", #second.sent, 0)
	second:hello(60000)
	h.equals("RESUME is the first frame", second.sent[1] and second.sent[1].op, Op.RESUME)
	h.equals("the queued presence follows the RESUME", second.sent[2] and second.sent[2].op, Op.PRESENCE_UPDATE)
	stop(harness)
end

-- The flush respects the send budget.
do
	local harness = start({ sendLimit = 3, sendWindow = 0.2 })
	local socket = harness:socket(1)
	for _ = 1, 3 do
		Gateway.requestGuildMembers(harness.gw, "123456789012345678")
	end
	local openedAt = Fakes.clock()
	socket:hello(60000) -- IDENTIFY: 1 of 3
	h.equals("the flush sends what fits in the budget at once", #socket:ofOp(Op.REQUEST_GUILD_MEMBERS), 2)
	Fakes.waitUntil(function()
		return #socket:ofOp(Op.REQUEST_GUILD_MEMBERS) == 3
	end, 1)
	local sent = socket:ofOp(Op.REQUEST_GUILD_MEMBERS)
	h.check(
		`the rest waited for the window ({string.format("%.3f", (sent[3] and sent[3].at or 0) - openedAt)}s)`,
		sent[3] ~= nil and sent[3].at - openedAt >= 0.2 - 0.03
	)
	stop(harness)
end

----------------------------------------------------------------------------
-- Which closes keep the session
----------------------------------------------------------------------------
-- Discord: resume after a disconnect with no close code, or one that allows
-- reconnecting; start over after 4007/4009 or a server 1000/1001. 1005 and
-- 1006 are the runtime saying no close frame arrived -- a network blip.
for _, case in {
	{ code = 1005, resume = true },
	{ code = 1006, resume = true },
	{ code = 1011, resume = true },
	{ code = 4000, resume = true },
	{ code = 4008, resume = true },
	{ code = 1000, resume = false },
	{ code = 1001, resume = false },
	{ code = 4007, resume = false },
	{ code = 4009, resume = false },
} do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-c")
	socket:dispatch("MESSAGE_CREATE", {}, 2)
	socket:serverClose(case.code, "")
	local second = harness:socket(2)
	second:hello(60000)
	if case.resume then
		h.equals(`server close {case.code} keeps the session`, harness.gw.sessionId, "sess-c")
		h.equals(`server close {case.code} dials the resume URL`, second.url, RESUME_URL .. QUERY)
		h.equals(`server close {case.code} RESUMEs`, #second:ofOp(Op.RESUME), 1)
	else
		h.equals(`server close {case.code} ends the session`, harness.gw.sessionId, nil)
		h.equals(`server close {case.code} dials the main gateway`, second.url, GATEWAY .. QUERY)
		h.equals(`server close {case.code} re-IDENTIFYs`, #second:ofOp(Op.IDENTIFY), 1)
	end
	stop(harness)
end

-- No close code at all (the stream just errored): resume.
do
	local harness = start()
	local socket = connectReady(harness, 1, "sess-e")
	local onerror = socket.handlers.onerror :: (string) -> ()
	onerror("connection reset by peer")
	local second = harness:socket(2)
	second:hello(60000)
	h.equals("a disconnect with no close code keeps the session", harness.gw.sessionId, "sess-e")
	h.equals("and RESUMEs", #second:ofOp(Op.RESUME), 1)
	stop(harness)
end

-- The identify gate is told when to give up, so stop() does not wait it out.
do
	local stopAsked = false
	local harness = start({
		identifyGate = function(awake: () -> boolean)
			while awake() do
				task.wait(0.01)
			end
			stopAsked = true
		end,
	})
	task.wait(0.03)
	stop(harness)
	h.check("a gate parked for its slot wakes when the shard stops", stopAsked and harness.finished)
	h.equals("and nothing was dialled", #harness.conn.sockets, 0)
end

h.finish()
