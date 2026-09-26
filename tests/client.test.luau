--!strict
--[[
	The client, end to end: a fake REST transport and a fake gateway socket,
	so every assertion is about what actually went over the wire -- the
	IDENTIFY that was sent, the interaction callback that was POSTed -- not
	about private state.

	Routing and cache tests feed dispatches through `Client._dispatch`, the
	same entry point a shard uses, to keep them short; the lifecycle tests
	go through the socket.
]]
local task = require("@lute/task")

local Client = require("@discord/client")
local Commands = require("@discord/commands")
local Const = require("@discord/const")
local Log = require("@discord/log")
local Fakes = require("./fakes")
local h = require("./harness")

local Op = Const.Op
local GUILD = "1541340259126607882"
local APP = "900000000000000001"

type Rig = {
	client: Client.Client,
	rest: Fakes.Rest,
	conn: Fakes.Connector,
}

local function rig(overrides: { [string]: any }?, shards: number?, maxConcurrency: number?): Rig
	local rest = Fakes.rest()
	rest:on("GET", "/gateway/bot", {
		status = 200,
		body = {
			url = "wss://gateway.discord.test",
			shards = shards or 1,
			session_start_limit = { total = 1000, remaining = 999, reset_after = 0, max_concurrency = maxConcurrency or 1 },
		},
	})
	rest:on("GET", "/applications/@me", { status = 200, body = { id = APP, name = "tofu" } })
	rest:on("PUT", "/applications/%d+/commands", function(call): Fakes.Reply?
		return { status = 200, body = call.json }
	end)
	rest:on("PUT", "/applications/%d+/guilds/%d+/commands", function(call): Fakes.Reply?
		return { status = 200, body = call.json }
	end)
	rest:on("POST", "/webhooks/%d+/[^/]+", { status = 200, body = { id = "followup" } })
	rest:on("PATCH", "/webhooks/%d+/[^/]+/messages/@original", { status = 200, body = { id = "original" } })

	local conn = Fakes.connector()
	local options: Client.Options = {
		token = "TOKEN",
		intents = { "guilds", "guildMessages" },
		logLevel = "error",
		http = { transport = rest.transport, baseUrl = Fakes.BASE, backoffBase = 0.005, backoffCap = 0.01 },
		gateway = { connect = conn.connect, backoffBase = 0.005, backoffCap = 0.01, identifyInterval = 0.05 },
	}
	for key, value in overrides or {} do
		(options :: any)[key] = value
	end
	return { client = Client.new(options), rest = rest, conn = conn }
end

local function socketAt(r: Rig, index: number): Fakes.FakeSocket
	Fakes.waitUntil(function()
		return #r.conn.sockets >= index
	end)
	return r.conn.sockets[index]
end

local interactionSeq = 0
local function interaction(kind: number, data: any, extra: { [string]: any }?): any
	interactionSeq += 1
	local raw: { [string]: any } = {
		id = tostring(700000000000000000 + interactionSeq),
		application_id = APP,
		type = kind,
		data = data,
		guild_id = GUILD,
		channel_id = "800000000000000001",
		member = { user = { id = "100000000000000001", username = "kid" }, roles = {}, joined_at = "x" },
		token = `tok{interactionSeq}`,
		version = 1,
	}
	for key, value in extra or {} do
		raw[key] = value
	end
	return raw
end

--- Interaction callbacks POSTed for interaction `raw`.
local function callbacks(r: Rig, raw: any): { any }
	local out = {}
	for _, call in r.rest:find("POST", `/interactions/{raw.id}/{raw.token}/callback`) do
		table.insert(out, call.json)
	end
	return out
end

local function settle()
	task.wait(0.02)
end

----------------------------------------------------------------------------
-- Intents
----------------------------------------------------------------------------
do
	h.equals("intent names resolve to a mask", rig().client.intents, 1 + 512)
	h.equals("a raw number passes through", rig({ intents = 32767 }).client.intents, 32767)
	h.throws("an unknown intent name is an error", 'unknown intent "guildMessage"', function()
		rig({ intents = { "guilds", "guildMessage" } })
	end)
	h.equals("privileged names resolve too", rig({ intents = { "messageContent" } }).client.intents, 2 ^ 15)
end

----------------------------------------------------------------------------
-- login: HELLO -> IDENTIFY -> READY -> ready, then dispatch -> listeners
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	local readyCount, readyPayload = 0, nil :: any
	local shardReady = {}
	client:on("ready", function(payload: any)
		readyCount += 1
		readyPayload = payload
	end)
	client:on("shardReady", function(shardId: any, resumed: any)
		table.insert(shardReady, { shardId, resumed })
	end)

	local loggedIn = false
	task.spawn(function()
		client:login()
		loggedIn = true
	end)
	local socket = socketAt(r, 1)
	h.equals("login dials the URL from /gateway/bot", socket.url, "wss://gateway.discord.test" .. Const.GATEWAY_QUERY)
	socket:hello(60000)
	local identify = socket:ofOp(Op.IDENTIFY)[1]
	h.equals("IDENTIFY carries the resolved intents", identify and identify.d.intents, 513)
	h.equals("IDENTIFY carries the token", identify and identify.d.token, "TOKEN")
	h.check("login has not returned before READY", not loggedIn)

	socket:dispatch("READY", Fakes.ready("sess"), 1)
	h.check("login returns once READY arrives", Fakes.waitUntil(function()
		return loggedIn
	end))
	h.equals("ready fired once", readyCount, 1)
	h.equals("ready carries the READY payload", readyPayload and readyPayload.session_id, "sess")
	h.check("shardReady(0, false)", shardReady[1] ~= nil and shardReady[1][1] == 0 and shardReady[1][2] == false)
	h.equals("client.user set from READY", client.user and client.user.username, "tofu")
	h.equals("applicationId set from READY", client.applicationId, APP)
	h.equals("the cache knows the bot's own user", client.cache.self and client.cache.self.id, APP)

	-- camelCase events, on/once/off, raw
	local seen, onceSeen, offSeen, raws = 0, 0, 0, {}
	client:on("messageCreate", function()
		seen += 1
	end)
	client:once("messageCreate", function()
		onceSeen += 1
	end)
	local handle = client:on("messageCreate", function()
		offSeen += 1
	end)
	client:off(handle)
	client:on("raw", function(event: any)
		table.insert(raws, event)
	end)
	socket:dispatch("MESSAGE_CREATE", { id = "m1", channel_id = "c", author = { id = "u1", username = "a" } }, 2)
	socket:dispatch("MESSAGE_CREATE", { id = "m2", channel_id = "c", author = { id = "u1", username = "a" } }, 3)
	settle()
	h.equals("MESSAGE_CREATE reaches messageCreate", seen, 2)
	h.equals("once fires once", onceSeen, 1)
	h.equals("off removes the listener", offSeen, 0)
	h.equals("raw sees every dispatch", raws[#raws], "MESSAGE_CREATE")

	-- A throwing listener emits `error` and does not stop the others.
	local errors, survivors = {}, 0
	client:on("error", function(err: any, context: any)
		table.insert(errors, { err, context })
	end)
	client:on("typingStart", function()
		error("listener exploded")
	end)
	client:on("typingStart", function()
		survivors += 1
	end)
	socket:dispatch("TYPING_START", { channel_id = "c" }, 4)
	settle()
	h.equals("the other listener still ran", survivors, 1)
	h.equals("error event raised with the context", errors[1] and errors[1][2], "typingStart")
	h.check("error carries the message", errors[1] ~= nil and string.find(tostring(errors[1][1]), "listener exploded", 1, true) ~= nil)

	-- waitFor
	local got: any = nil
	task.spawn(function()
		got = client:waitFor("messageCreate", function(message: any): boolean
			return message.author.id == "u2"
		end, 1)
	end)
	socket:dispatch("MESSAGE_CREATE", { id = "m3", channel_id = "c", author = { id = "u1", username = "a" } }, 5)
	socket:dispatch("MESSAGE_CREATE", { id = "m4", channel_id = "c", author = { id = "u2", username = "b" } }, 6)
	Fakes.waitUntil(function()
		return got ~= nil
	end)
	h.equals("waitFor returns the first event its filter accepts", got and got.id, "m4")
	local started = Fakes.clock()
	local none = client:waitFor("guildBanAdd", nil, 0.05)
	h.equals("waitFor returns nil on timeout", none, nil)
	h.check("and does not overstay the timeout", Fakes.clock() - started < 0.3)
	local count = 0
	for _, list in client._listeners do
		for _, listener in list do
			if listener.event == "guildBanAdd" then
				count += 1
			end
		end
	end
	h.equals("a timed-out waitFor unregisters its listener", count, 0)

	-- shardDisconnect / shardResume / resumed
	local disconnects, resumes, resumed = {}, {}, 0
	client:on("shardDisconnect", function(shardId: any, code: any)
		table.insert(disconnects, { shardId, code })
	end)
	client:on("shardResume", function(shardId: any)
		table.insert(resumes, shardId)
	end)
	client:on("resumed", function()
		resumed += 1
	end)
	socket:serverClose(4000, "")
	local second = socketAt(r, 2)
	second:hello(60000)
	h.equals("reconnect resumes", #second:ofOp(Op.RESUME), 1)
	second:dispatch("RESUMED", {}, 7)
	settle()
	h.check("shardDisconnect(0, 4000)", disconnects[1] ~= nil and disconnects[1][1] == 0 and disconnects[1][2] == 4000)
	h.equals("shardResume(0)", resumes[1], 0)
	h.check("shardReady(0, true) after the resume", shardReady[2] ~= nil and shardReady[2][2] == true)
	h.equals("resumed event still fires", resumed, 1)
	h.equals("ready did not fire again", readyCount, 1)

	-- fetchMembers: op 8 on the right shard, chunks collected by nonce.
	local members: any = nil
	task.spawn(function()
		members = client:fetchMembers(GUILD, { query = "to", limit = 10 })
	end)
	local op8 = second:ofOp(Op.REQUEST_GUILD_MEMBERS)[1]
	h.check("fetchMembers sent op 8", op8 ~= nil)
	local nonce = op8 and op8.d.nonce
	h.equals("op 8 names the guild", op8 and op8.d.guild_id, GUILD)
	h.equals("op 8 carries the query", op8 and op8.d.query, "to")
	h.check("op 8 carries a nonce", type(nonce) == "string" and #nonce > 0 and #nonce <= 32)
	-- A chunk for someone else's request must not be collected.
	second:dispatch("GUILD_MEMBERS_CHUNK", {
		guild_id = GUILD,
		nonce = "other",
		chunk_index = 0,
		chunk_count = 1,
		members = { { user = { id = "999", username = "x" }, roles = {}, joined_at = "x" } },
	}, 8)
	second:dispatch("GUILD_MEMBERS_CHUNK", {
		guild_id = GUILD,
		nonce = nonce,
		chunk_index = 0,
		chunk_count = 2,
		members = {
			{ user = { id = "201", username = "tofu1" }, roles = {}, joined_at = "x" },
			{ user = { id = "202", username = "tofu2" }, roles = {}, joined_at = "x" },
		},
	}, 9)
	h.equals("not done after the first of two chunks", members, nil)
	second:dispatch("GUILD_MEMBERS_CHUNK", {
		guild_id = GUILD,
		nonce = nonce,
		chunk_index = 1,
		chunk_count = 2,
		members = { { user = { id = "203", username = "tofu3" }, roles = {}, joined_at = "x" } },
	}, 10)
	Fakes.waitUntil(function()
		return members ~= nil
	end)
	h.equals("fetchMembers returns every chunk's members", members and #members, 3)
	h.check("and they were cached", client.cache:getMember(GUILD, "203") ~= nil)
	h.throws("fetchMembers times out when no chunk comes", "timed out", function()
		client:fetchMembers(GUILD, { userIds = { "1" }, timeout = 0.05 })
	end)
	local lookup = second:ofOp(Op.REQUEST_GUILD_MEMBERS)[2]
	h.check("a userIds lookup sends user_ids and no query", lookup ~= nil and lookup.d.user_ids[1] == "1" and lookup.d.query == nil)

	-- Voice state on the guild's shard.
	h.check("updateVoiceState goes out on the guild's shard", client:updateVoiceState(GUILD, "800000000000000009", true))
	h.equals("op 4 sent", #second:ofOp(Op.VOICE_STATE_UPDATE), 1)

	-- stop: run-style shutdown leaves nothing behind.
	client:stop()
	h.check("stop closed the socket", second.closedByClient)
	h.check("every shard's run loop ended", Fakes.waitUntil(function()
		return client.shards[1].state == "stopped"
	end, 1))
end

----------------------------------------------------------------------------
-- shardFor
----------------------------------------------------------------------------
do
	local r = rig({ shardCount = 4 })
	-- (1541340259126607882 >> 22) % n, worked out with exact integers.
	h.equals("shardFor with 1 shard", rig().client:shardFor(GUILD), 0)
	h.equals("shardFor with 4 shards", r.client:shardFor(GUILD), 1)
	r.client.shardCount = 16
	h.equals("shardFor with 16 shards", r.client:shardFor(GUILD), 13)
	h.equals("shardFor on a smaller id", r.client:shardFor("41771983423143937"), 6)
	h.throws("shardFor rejects a non-snowflake", "not a snowflake", function()
		r.client:shardFor("12a")
	end)
end

----------------------------------------------------------------------------
-- Several shards: IDENTIFY pacing, `ready` once all are up, fatal stops all
----------------------------------------------------------------------------
do
	local r = rig({ shardCount = 2 })
	local client = r.client
	local readyCount = 0
	client:on("ready", function()
		readyCount += 1
	end)
	local finished = false
	local runError: any = nil
	task.spawn(function()
		local ok, err = pcall(client.run, client)
		runError = if ok then nil else err
		finished = true
	end)
	local first = socketAt(r, 1)
	local second = socketAt(r, 2)
	local spacing = second.openedAt - first.openedAt
	h.check(
		`with max_concurrency 1 the second shard dials an identify interval later ({string.format("%.3f", spacing)}s)`,
		spacing >= 0.05 - 0.02
	)
	first:hello(60000)
	second:hello(60000)
	-- The second IDENTIFY waits for its slot at send time as well.
	Fakes.waitUntil(function()
		return #first:ofOp(Op.IDENTIFY) == 1 and #second:ofOp(Op.IDENTIFY) == 1
	end, 1)
	local shards = {}
	for _, socket in { first, second } do
		local identify = socket:ofOp(Op.IDENTIFY)[1]
		table.insert(shards, identify and identify.d.shard[1])
	end
	table.sort(shards)
	h.check("each shard identifies with its own id", shards[1] == 0 and shards[2] == 1)
	first:dispatch("READY", Fakes.ready("a"), 1)
	settle()
	h.equals("ready waits for every shard", readyCount, 0)
	second:dispatch("READY", Fakes.ready("b"), 1)
	settle()
	h.equals("ready fires once all shards are READY", readyCount, 1)

	-- fetchMembers goes to shard (guild >> 22) % 2 = 1.
	task.spawn(function()
		pcall(function()
			client:fetchMembers(GUILD, { timeout = 0.05 })
		end)
	end)
	local shardOne = if first:ofOp(Op.IDENTIFY)[1].d.shard[1] == 1 then first else second
	local shardZero = if shardOne == first then second else first
	h.equals("op 8 went to the guild's shard", #shardOne:ofOp(Op.REQUEST_GUILD_MEMBERS), 1)
	h.equals("and not to the other one", #shardZero:ofOp(Op.REQUEST_GUILD_MEMBERS), 0)

	-- A fatal close on one shard stops the whole client.
	shardZero:serverClose(4004, "Authentication failed.")
	h.check("a fatal close ends run()", Fakes.waitUntil(function()
		return finished
	end, 1))
	h.check("the healthy shard was stopped too", shardOne.closedByClient)
	h.check("the reason is recorded", client.fatalReason ~= nil)
	-- A service manager must see an auth failure as a failure.
	h.check("run() raises after a fatal close", type(runError) == "string")
	h.check(
		"naming the reason",
		type(runError) == "string" and string.find(runError, "could not stay connected: authentication failed", 1, true) == 1
	)
end

-- IDENTIFY pacing by max_concurrency, on the gate itself.
do
	local gate = Client._makeIdentifyGate(2, 0.1)
	local times: { [number]: number } = {}
	local startedAt = Fakes.clock()
	for shardId = 0, 4 do
		task.spawn(function()
			gate(shardId)
			times[shardId] = Fakes.clock() - startedAt
		end)
	end
	Fakes.waitUntil(function()
		return times[4] ~= nil
	end, 1)
	h.check("shards 0 and 1 (different buckets) identify at once", times[0] < 0.03 and times[1] < 0.03)
	h.check(`shard 2 waits for bucket 0 ({string.format("%.3f", times[2] or -1)}s)`, (times[2] or 0) >= 0.1 - 0.01)
	h.check(`shard 3 waits for bucket 1 ({string.format("%.3f", times[3] or -1)}s)`, (times[3] or 0) >= 0.1 - 0.01)
	h.check(`shard 4 waits two slots ({string.format("%.3f", times[4] or -1)}s)`, (times[4] or 0) >= 0.2 - 0.01)
end

-- login throws on a fatal close before READY.
do
	local r = rig()
	local result: { ok: boolean, err: any }? = nil
	task.spawn(function()
		local ok, err = pcall(r.client.login, r.client)
		result = { ok = ok, err = err }
	end)
	local socket = socketAt(r, 1)
	socket:hello(60000)
	socket:serverClose(4014, "Disallowed intent(s).")
	Fakes.waitUntil(function()
		return result ~= nil
	end, 1)
	local outcome = result :: { ok: boolean, err: any }
	h.check("login throws on a fatal close", outcome ~= nil and not outcome.ok)
	h.check("naming the reason", outcome ~= nil and string.find(tostring(outcome.err), "disallowed intents", 1, true) ~= nil)
end

-- run() returns promptly after stop, with a heartbeat running.
do
	local r = rig()
	local finished = false
	task.spawn(function()
		local ok = pcall(r.client.run, r.client)
		finished = ok
	end)
	local socket = socketAt(r, 1)
	socket:hello(30000)
	socket:dispatch("READY", Fakes.ready("s"), 1)
	settle()
	local stoppedAt = Fakes.clock()
	r.client:stop()
	h.check("run returns promptly after stop", Fakes.waitUntil(function()
		return finished
	end, 0.5))
	h.check(`within a fraction of a second ({string.format("%.3f", Fakes.clock() - stoppedAt)}s)`, Fakes.clock() - stoppedAt < 0.3)
	h.equals("a return from stop() is not an error", r.client.fatalReason, nil)
end

----------------------------------------------------------------------------
-- Interaction routing (fed through _dispatch; REST via the fake)
----------------------------------------------------------------------------
Log.setLevel("error")
do
	local r = rig()
	local client = r.client
	client.applicationId = APP
	local hits = {}
	client:command("role add", function(ix)
		table.insert(hits, "role add")
		ix:reply("added")
	end)
	client:command("config", function()
		table.insert(hits, "config")
	end)

	local roleAdd = interaction(2, {
		name = "role",
		options = { { type = 1, name = "add", options = { { type = 3, name = "name", value = "x" } } } },
	})
	client:_dispatch("INTERACTION_CREATE", roleAdd)
	settle()
	h.equals("full subcommand path routes to its handler", hits[1], "role add")
	h.equals("the handler's reply was a type-4 callback", callbacks(r, roleAdd)[1] and callbacks(r, roleAdd)[1].type, 4)

	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "config", options = { { type = 1, name = "set" } } }))
	settle()
	h.equals("an unregistered subcommand falls back to the bare name", hits[2], "config")

	local seenCreate = 0
	client:on("interactionCreate", function()
		seenCreate += 1
	end)
	local unknown = interaction(2, { name = "nope" })
	client:_dispatch("INTERACTION_CREATE", unknown)
	settle()
	local reply = callbacks(r, unknown)[1]
	h.equals("unknown command gets a reply", reply and reply.type, 4)
	h.equals("and it is ephemeral", reply and reply.data.flags, 64)
	h.equals("interactionCreate still emitted after routing", seenCreate, 1)

	-- Autocomplete with no handler: an empty choice list.
	local auto = interaction(4, { name = "role", options = { { type = 3, name = "q", value = "a", focused = true } } })
	client:_dispatch("INTERACTION_CREATE", auto)
	settle()
	local answer = callbacks(r, auto)[1]
	h.equals("autocomplete without a handler answers type 8", answer and answer.type, 8)
	h.equals("with no choices", answer and #answer.data.choices, 0)

	local autoHits = 0
	client:autocomplete("role", function(ix)
		autoHits += 1
		ix:autocomplete({ { name = "a", value = "a" } })
	end)
	local auto2 = interaction(4, { name = "role", options = { { type = 1, name = "add", options = {} } } })
	client:_dispatch("INTERACTION_CREATE", auto2)
	settle()
	h.equals("autocomplete handler found by bare-name fallback", autoHits, 1)

	-- Components: collectors first, then the longest prefix.
	local compHits = {}
	client:component("poll:", function()
		table.insert(compHits, "poll:")
	end)
	client:component("poll:yes", function()
		table.insert(compHits, "poll:yes")
	end)
	client:_dispatch("INTERACTION_CREATE", interaction(3, { custom_id = "poll:yes:1", component_type = 2 }, { message = { id = "m9" } }))
	client:_dispatch("INTERACTION_CREATE", interaction(3, { custom_id = "poll:no", component_type = 2 }, { message = { id = "m9" } }))
	settle()
	h.equals("longest prefix wins", compHits[1], "poll:yes")
	h.equals("shorter prefix catches the rest", compHits[2], "poll:")

	local collected = {}
	local collector = client:collect({
		messageId = "m1",
		timeout = 0,
		onCollect = function(ix)
			table.insert(collected, ix.data.custom_id)
		end,
	})
	client:_dispatch("INTERACTION_CREATE", interaction(3, { custom_id = "poll:yes", component_type = 2 }, { message = { id = "m1" } }))
	settle()
	h.equals("a matching collector gets first refusal", collected[1], "poll:yes")
	h.equals("so the prefix handler did not run", #compHits, 2)
	collector:stop()

	local orphan = interaction(3, { custom_id = "gone:1", component_type = 2 }, { message = { id = "m2" } })
	client:_dispatch("INTERACTION_CREATE", orphan)
	settle()
	h.equals("an unhandled component is deferred (type 6)", callbacks(r, orphan)[1] and callbacks(r, orphan)[1].type, 6)

	-- Modals: collectors first, then prefix; unhandled gets an ephemeral note.
	local modalHits = {}
	client:modal("form:", function(ix)
		table.insert(modalHits, ix.data.custom_id)
	end)
	client:_dispatch("INTERACTION_CREATE", interaction(5, { custom_id = "form:42", components = {} }))
	settle()
	h.equals("modal routed by prefix", modalHits[1], "form:42")

	local modalCollected = {}
	local modalCollector = client:collect({
		userId = "100000000000000001",
		filter = function(ix): boolean
			return ix.type == 5
		end,
		timeout = 0,
		onCollect = function(ix)
			table.insert(modalCollected, ix.data.custom_id)
		end,
	})
	client:_dispatch("INTERACTION_CREATE", interaction(5, { custom_id = "form:43", components = {} }))
	settle()
	h.equals("a modal collector gets first refusal too", modalCollected[1], "form:43")
	h.equals("so the modal prefix handler did not run", #modalHits, 1)
	modalCollector:stop()

	local stale = interaction(5, { custom_id = "old:1", components = {} })
	client:_dispatch("INTERACTION_CREATE", stale)
	settle()
	local note = callbacks(r, stale)[1]
	h.check("an unhandled modal gets an ephemeral reply", note ~= nil and note.type == 4 and note.data.flags == 64)
end

----------------------------------------------------------------------------
-- A throwing handler: error notice, follow-up when acknowledged, opt-out
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	local errors = {}
	client:on("error", function(_err: any, context: any)
		table.insert(errors, context)
	end)
	client:command("boom", function()
		error("handler broke")
	end)
	client:command("late", function(ix)
		ix:defer(true)
		error("broke after deferring")
	end)

	local boom = interaction(2, { name = "boom" })
	client:_dispatch("INTERACTION_CREATE", boom)
	settle()
	local notice = callbacks(r, boom)[1]
	h.equals("a throw is answered with the error notice", notice and notice.data.content, "Something went wrong running that.")
	h.equals("ephemerally", notice and notice.data.flags, 64)
	h.equals("and raises `error` with the label", errors[1], "command /boom")
	h.check("the traceback is not sent to the user", notice ~= nil and string.find(notice.data.content, "handler broke", 1, true) == nil)

	local late = interaction(2, { name = "late" })
	client:_dispatch("INTERACTION_CREATE", late)
	settle()
	h.equals("the defer went out as the callback", callbacks(r, late)[1] and callbacks(r, late)[1].type, 5)
	-- A follow-up would leave the "thinking..." placeholder up forever; the
	-- notice has to replace it. The deferral already fixed its visibility.
	local edits = r.rest:find("PATCH", `/webhooks/{APP}/{late.token}/messages/@original`)
	h.equals("a deferred interaction gets its placeholder edited", #edits, 1)
	h.equals("with the notice", edits[1] and edits[1].json.content, "Something went wrong running that.")
	h.equals("and no follow-up", #r.rest:find("POST", `/webhooks/{APP}/{late.token}`), 0)

	-- Answered for real (not merely deferred): the notice is a follow-up.
	client:command("answered", function(ix)
		ix:reply("partial result")
		error("broke after replying")
	end)
	local answered = interaction(2, { name = "answered" })
	client:_dispatch("INTERACTION_CREATE", answered)
	settle()
	local followups = r.rest:find("POST", `/webhooks/{APP}/{answered.token}`)
	h.equals("an answered interaction gets a follow-up instead", #followups, 1)
	h.equals("the follow-up is ephemeral", followups[1] and followups[1].json.flags, 64)

	client.options.errorMessage = "Oops."
	local custom = interaction(2, { name = "boom" })
	client:_dispatch("INTERACTION_CREATE", custom)
	settle()
	h.equals("a custom errorMessage is used", callbacks(r, custom)[1] and callbacks(r, custom)[1].data.content, "Oops.")

	client.options.errorMessage = false
	local silent = interaction(2, { name = "boom" })
	client:_dispatch("INTERACTION_CREATE", silent)
	settle()
	h.equals("errorMessage = false sends nothing", #callbacks(r, silent), 0)
end

----------------------------------------------------------------------------
-- Cache maintenance
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	local cache = client.cache
	local function role(id: string, name: string): any
		return { id = id, name = name, position = 1, permissions = "0", color = 0, hoist = false, managed = false, mentionable = false }
	end
	client:_dispatch("GUILD_CREATE", {
		id = GUILD,
		name = "Tofu",
		owner_id = "1",
		member_count = 3,
		roles = { role(GUILD, "@everyone"), role("r1", "Deputy") },
		channels = { { id = "c1", type = 0, name = "general" }, { id = "forum", type = 15, name = "forum" } },
		threads = { { id = "t1", type = 11, parent_id = "forum", name = "old thread" } },
		members = { { user = { id = "u1", username = "kid" }, roles = {}, joined_at = "2020" } },
		emojis = {},
	})
	h.check("GUILD_CREATE caches the guild", cache:getGuild(GUILD) ~= nil)
	h.check("and its channels", cache:getChannel("c1") ~= nil)
	h.check("and its active threads", cache:getChannel("t1") ~= nil)
	h.check("and its roles", cache:getRole(GUILD, "r1") ~= nil)
	h.check("and its members", cache:getMember(GUILD, "u1") ~= nil)

	client:_dispatch("GUILD_UPDATE", { id = GUILD, name = "Tofu 2", owner_id = "1", roles = { role(GUILD, "@everyone") } })
	local guild = cache:getGuild(GUILD) :: any
	h.equals("GUILD_UPDATE changes fields", guild.name, "Tofu 2")
	h.equals("without dropping GUILD_CREATE-only ones", guild.member_count, 3)
	h.equals("and refreshes the role map", cache:getRole(GUILD, "r1"), nil)

	client:_dispatch("GUILD_ROLE_CREATE", { guild_id = GUILD, role = role("r2", "Marshal") })
	h.check("GUILD_ROLE_CREATE", cache:getRole(GUILD, "r2") ~= nil)
	client:_dispatch("GUILD_ROLE_UPDATE", { guild_id = GUILD, role = role("r2", "Sheriff") })
	h.equals("GUILD_ROLE_UPDATE", (cache:getRole(GUILD, "r2") :: any).name, "Sheriff")
	client:_dispatch("GUILD_ROLE_DELETE", { guild_id = GUILD, role_id = "r2" })
	h.equals("GUILD_ROLE_DELETE", cache:getRole(GUILD, "r2"), nil)

	client:_dispatch("CHANNEL_CREATE", { id = "c2", type = 0, guild_id = GUILD, name = "new" })
	h.check("CHANNEL_CREATE", cache:getChannel("c2") ~= nil)
	client:_dispatch("CHANNEL_UPDATE", { id = "c2", type = 0, guild_id = GUILD, name = "renamed" })
	h.equals("CHANNEL_UPDATE", (cache:getChannel("c2") :: any).name, "renamed")
	client:_dispatch("CHANNEL_DELETE", { id = "c2", type = 0, guild_id = GUILD })
	h.equals("CHANNEL_DELETE", cache:getChannel("c2"), nil)

	client:_dispatch("THREAD_CREATE", { id = "t2", type = 11, guild_id = GUILD, parent_id = "c1", name = "t" })
	client:_dispatch("THREAD_UPDATE", { id = "t2", type = 11, guild_id = GUILD, parent_id = "c1", name = "renamed thread" })
	h.equals("THREAD_UPDATE", (cache:getChannel("t2") :: any).name, "renamed thread")

	-- A sync for "forum" drops its stale thread t1 and adds t3; t2 (under c1,
	-- not in the sync) is untouched.
	client:_dispatch("THREAD_LIST_SYNC", {
		guild_id = GUILD,
		channel_ids = { "forum" },
		threads = { { id = "t3", type = 11, parent_id = "forum", name = "new thread" } },
		members = {},
	})
	h.equals("THREAD_LIST_SYNC drops threads it no longer lists", cache:getChannel("t1"), nil)
	h.check("and adds the ones it does", cache:getChannel("t3") ~= nil)
	h.check("threads under other parents survive", cache:getChannel("t2") ~= nil)
	h.check("non-thread channels are never dropped", cache:getChannel("forum") ~= nil)
	client:_dispatch("THREAD_LIST_SYNC", { guild_id = GUILD, threads = {}, members = {} })
	h.equals("a whole-guild sync clears every stale thread", cache:getChannel("t2"), nil)
	client:_dispatch("THREAD_DELETE", { id = "t3", type = 11, guild_id = GUILD, parent_id = "forum" })
	h.equals("THREAD_DELETE", cache:getChannel("t3"), nil)

	client:_dispatch("GUILD_MEMBER_ADD", { guild_id = GUILD, user = { id = "u2", username = "new" }, roles = {}, joined_at = "2021", deaf = false })
	h.check("GUILD_MEMBER_ADD", cache:getMember(GUILD, "u2") ~= nil)
	client:_dispatch("GUILD_MEMBER_UPDATE", { guild_id = GUILD, user = { id = "u2", username = "new" }, roles = { "r1" }, nick = "Newbie" })
	local member = cache:getMember(GUILD, "u2") :: any
	h.equals("GUILD_MEMBER_UPDATE applies the change", member.nick, "Newbie")
	h.equals("and keeps fields the update omits", member.joined_at, "2021")
	client:_dispatch("GUILD_MEMBER_REMOVE", { guild_id = GUILD, user = { id = "u2", username = "new" } })
	h.equals("GUILD_MEMBER_REMOVE", cache:getMember(GUILD, "u2"), nil)

	client:_dispatch("GUILD_EMOJIS_UPDATE", { guild_id = GUILD, emojis = { { id = "e1", name = "tofu" } } })
	h.equals("GUILD_EMOJIS_UPDATE replaces the emoji list", #((cache:getGuild(GUILD) :: any).emojis), 1)

	client:_dispatch("MESSAGE_CREATE", {
		id = "m",
		channel_id = "c1",
		guild_id = GUILD,
		author = { id = "u3", username = "talker" },
		member = { roles = {}, joined_at = "2022" },
	})
	h.check("MESSAGE_CREATE caches the author", cache:getUser("u3") ~= nil)
	h.check("and the member, with its user spliced in", cache:getMember(GUILD, "u3") ~= nil)

	client:_dispatch("READY", Fakes.ready("s"))
	client:_dispatch("USER_UPDATE", { id = APP, username = "tofu-renamed" })
	h.equals("USER_UPDATE for the bot updates client.user", client.user and client.user.username, "tofu-renamed")
	h.equals("and the cache's own user", cache.self and cache.self.username, "tofu-renamed")

	-- Outages: unavailable guilds are flagged, never stored as stubs.
	client:_dispatch("GUILD_DELETE", { id = GUILD, unavailable = true })
	h.check("GUILD_DELETE during an outage keeps the guild", cache:getGuild(GUILD) ~= nil)
	h.equals("flagged unavailable", (cache:getGuild(GUILD) :: any).unavailable, true)
	client:_dispatch("GUILD_CREATE", { id = GUILD, unavailable = true })
	h.equals("an unavailable GUILD_CREATE does not wipe the known guild", (cache:getGuild(GUILD) :: any).name, "Tofu 2")
	client:_dispatch("GUILD_CREATE", { id = "5", unavailable = true })
	h.equals("nor does it store a nameless stub", cache:getGuild("5"), nil)
	client:_dispatch("GUILD_DELETE", { id = GUILD })
	h.equals("GUILD_DELETE (kicked) removes the guild", cache:getGuild(GUILD), nil)
	h.equals("and its channels", cache:getChannel("c1"), nil)
end

----------------------------------------------------------------------------
-- deploy: guild vs global, application id fetched when unknown
----------------------------------------------------------------------------
do
	local r = rig()
	local commands = { { name = "ping", description = "pong", type = 1 } }
	local result = r.client:deploy(commands :: any)
	h.equals("deploy fetched the application id first", #r.rest:find("GET", "/applications/@me"), 1)
	h.equals("global deploy uses the global route", #r.rest:find("PUT", `/applications/{APP}/commands`), 1)
	h.equals("and returns Discord's answer", result[1] and result[1].name, "ping")

	r.client:deploy(commands :: any, GUILD)
	h.equals("guild deploy uses the guild route", #r.rest:find("PUT", `/applications/{APP}/guilds/{GUILD}/commands`), 1)
	h.equals("the application id is remembered", #r.rest:find("GET", "/applications/@me"), 1)
	local body = r.rest:find("PUT", `/applications/{APP}/guilds/{GUILD}/commands`)[1].json
	h.equals("the command list is the body", body and body[1].name, "ping")
end

----------------------------------------------------------------------------
-- IDENTIFY spacing is measured when IDENTIFY is sent, not when dialled
----------------------------------------------------------------------------
-- Shard 0's handshake is slow and shard 1's is fast; spacing the dials alone
-- would put their IDENTIFYs almost together.
do
	local r = rig({ shardCount = 2 })
	r.conn.dialDelays[1] = 0.09
	task.spawn(function()
		r.client:run()
	end)
	local first = socketAt(r, 1)
	Fakes.waitUntil(function()
		return first.dialled
	end)
	first:hello(60000)
	local second = socketAt(r, 2)
	Fakes.waitUntil(function()
		return second.dialled
	end)
	second:hello(60000)
	Fakes.waitUntil(function()
		return #second:ofOp(Op.IDENTIFY) == 1
	end, 1)
	local a, b = first:ofOp(Op.IDENTIFY)[1], second:ofOp(Op.IDENTIFY)[1]
	local gap = if a ~= nil and b ~= nil then b.at - a.at else -1
	h.check(`IDENTIFYs of one bucket are an interval apart when sent ({string.format("%.3f", gap)}s)`, gap >= 0.05 - 0.01)
	r.client:stop()
end

----------------------------------------------------------------------------
-- stop() with shards still queued for their IDENTIFY slot
----------------------------------------------------------------------------
do
	local r = rig({ shardCount = 3, gateway = nil })
	r.client.options.gateway = { connect = r.conn.connect, backoffBase = 0.005, backoffCap = 0.01, identifyInterval = 2 }
	task.spawn(function()
		r.client:run()
	end)
	socketAt(r, 1)
	local stoppedAt = Fakes.clock()
	r.client:stop()
	local allStopped = Fakes.waitUntil(function()
		for _, shard in r.client.shards do
			if shard.state ~= "stopped" then
				return false
			end
		end
		return true
	end, 1)
	h.check(
		`shards queued behind the identify gate stop promptly ({string.format("%.3f", Fakes.clock() - stoppedAt)}s)`,
		allStopped and Fakes.clock() - stoppedAt < 0.5
	)
	h.equals("and never dialled", #r.conn.sockets, 1)
end

----------------------------------------------------------------------------
-- setPresence between connections is kept for the next IDENTIFY
----------------------------------------------------------------------------
do
	local r = rig()
	task.spawn(function()
		r.client:login()
	end)
	local socket = socketAt(r, 1)
	socket:hello(60000)
	socket:dispatch("READY", Fakes.ready("sess"), 1)
	socket:push({ op = Op.INVALID_SESSION, d = false })
	-- Between sockets: no connection to send on, but the presence is kept.
	r.client:setPresence(Client.presence("watching", "the reconnect"))
	local second = socketAt(r, 2)
	second:hello(60000)
	local identify = second:ofOp(Op.IDENTIFY)[1]
	h.equals(
		"a presence set while disconnected is carried by the next IDENTIFY",
		identify and identify.d.presence.activities[1].name,
		"the reconnect"
	)
	r.client:stop()
end

----------------------------------------------------------------------------
-- Client.new leaves the process-wide log alone unless asked
----------------------------------------------------------------------------
do
	local Fs = require("@lute/fs")
	local path = "./tests/.client-log-probe.log"
	pcall(Fs.remove, path)
	Log.setLevel("warn")
	Log.setFile(path)
	Client.new({ token = "TOKEN", intents = 0 })
	h.check("Client.new without logLevel keeps the bot's Log.setLevel", not Log.enabled("info") and Log.enabled("warn"))
	Log.warn("probe after Client.new")
	Log.setFile(nil)
	local text = ""
	pcall(function()
		local handle = Fs.open(path, "r")
		text = Fs.read(handle)
		Fs.close(handle)
	end)
	pcall(Fs.remove, path)
	h.check("Client.new without logFile keeps the bot's Log.setFile", string.find(text, "probe after Client.new", 1, true) ~= nil)
	Client.new({ token = "TOKEN", intents = 0, logLevel = "error" })
	h.check("an explicit logLevel still applies", not Log.enabled("warn"))
end

----------------------------------------------------------------------------
-- Diagnostics capture, for the tests below
----------------------------------------------------------------------------
type Line = { level: string, message: string }

--- Lines logged at info and above while `fn` runs.
local function capture(fn: () -> ()): { Line }
	local lines: { Line } = {}
	Log.setHook(function(level: string, message: string)
		table.insert(lines, { level = level, message = message })
	end)
	Log.setLevel("info")
	fn()
	Log.setLevel("error")
	Log.setHook(nil)
	return lines
end

local function logged(lines: { Line }, level: string, fragment: string): number
	local n = 0
	for _, line in lines do
		if line.level == level and string.find(line.message, fragment, 1, true) ~= nil then
			n += 1
		end
	end
	return n
end

----------------------------------------------------------------------------
-- Client.new rejects misspelled options
----------------------------------------------------------------------------
do
	h.throws("a misspelled option names the right one", 'Client.new has no option "logLvel"; did you mean "logLevel"?', function()
		Client.new({ token = "TOKEN", intents = 0, logLvel = "debug" } :: any)
	end)
	h.throws("a wire-style name is suggested in camelCase", 'did you mean "shardCount"?', function()
		Client.new({ token = "TOKEN", intents = 0, shard_count = 2 } :: any)
	end)
	h.check("every documented option is accepted", pcall(Client.new, {
		token = "TOKEN",
		intents = 0,
		cache = false,
		logLevel = "error",
		shardCount = 1,
		errorMessage = "x",
		showErrors = false,
		http = {},
		gateway = {},
	} :: any))
end

----------------------------------------------------------------------------
-- register + deploy(): handlers from the builders, routed by path
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	local hits = {}
	local ping = Commands.slash("ping", "Check I am alive"):handle(function(ix)
		table.insert(hits, "ping")
		return ix:reply("pong")
	end)
	local role = Commands.slash("role", "Roles")
		:subcommand("add", "Add a role", function(sub)
			sub:stringOption("name", "Role name", { autocomplete = true })
			sub:handle(function()
				table.insert(hits, "role add")
			end)
			sub:onAutocomplete(function(ix)
				table.insert(hits, "role add (autocomplete)")
				ix:autocomplete({ { name = "Deputy", value = "deputy" } })
			end)
		end)
		:subcommand("remove", "Remove a role", function(sub)
			sub:handle(function()
				table.insert(hits, "role remove")
			end)
		end)

	h.throws("deploy() with nothing registered is an error", "client:register", function()
		client:deploy()
	end)
	h.equals("register also takes builders as arguments", #client:register(ping), 1)
	h.throws("register rejects a plain command table", "not a command builder", function()
		client:register({ { name = "x", description = "y" } } :: any)
	end)

	local returned = client:register({ ping, role })
	h.equals("register returns the list", returned[2], role)
	client:register({ ping }) -- again: must not duplicate
	local lines = capture(function()
		client:deploy(nil, GUILD)
	end)
	local body = r.rest:find("PUT", `/applications/{APP}/guilds/{GUILD}/commands`)[1]
	h.equals("deploy() publishes every registered command, once each", body and #body.json, 2)
	h.equals("as their payloads", body and body.json[2].options[1].name, "add")
	h.equals("and a fully wired deploy warns about nothing", logged(lines, "warn", ""), 0)

	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "ping", type = 1 }))
	client:_dispatch("INTERACTION_CREATE", interaction(2, {
		name = "role",
		type = 1,
		options = { { type = 1, name = "remove", options = {} } },
	}))
	local auto = interaction(4, {
		name = "role",
		type = 1,
		options = { { type = 1, name = "add", options = { { type = 3, name = "name", value = "de", focused = true } } } },
	})
	client:_dispatch("INTERACTION_CREATE", auto)
	settle()
	h.check("a registered command handler runs", table.find(hits, "ping") ~= nil)
	h.check("a registered subcommand handler runs by its path", table.find(hits, "role remove") ~= nil)
	h.check("a registered autocomplete handler runs", table.find(hits, "role add (autocomplete)") ~= nil)
	h.equals("and answers the autocomplete", callbacks(r, auto)[1] and callbacks(r, auto)[1].type, 8)

	-- An explicit list still wins over the registered set.
	client:deploy({ { name = "ping", description = "pong", type = 1 } } :: any)
	local global = r.rest:find("PUT", `/applications/{APP}/commands`)[1]
	h.equals("an explicit list is deployed as given", global and #global.json, 1)
end

----------------------------------------------------------------------------
-- Handlers are keyed by command type
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	local hits = {}
	client:register({
		Commands.slash("info", "About something"):handle(function()
			table.insert(hits, "slash")
		end),
		Commands.userCommand("info"):handle(function()
			table.insert(hits, "user")
		end),
	})
	client:command("Report", function()
		table.insert(hits, "untyped")
	end)
	client:command("Report", function()
		table.insert(hits, "message-typed")
	end, Const.CommandType.MESSAGE)

	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "info", type = Const.CommandType.CHAT_INPUT }))
	settle()
	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "info", type = Const.CommandType.USER, target_id = "1" }))
	settle()
	h.equals("/info goes to the slash handler", hits[1], "slash")
	h.equals("the user command \"info\" goes to its own", hits[2], "user")

	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "Report", type = Const.CommandType.MESSAGE, target_id = "1" }))
	settle()
	h.equals("a handler for the exact type beats an untyped one", hits[3], "message-typed")
	client:_dispatch("INTERACTION_CREATE", interaction(2, { name = "Report", type = Const.CommandType.USER, target_id = "1" }))
	settle()
	h.equals("an untyped handler answers any type without its own", hits[4], "untyped")

	local stray = interaction(2, { name = "info", type = Const.CommandType.MESSAGE, target_id = "1" })
	client:_dispatch("INTERACTION_CREATE", stray)
	settle()
	h.equals("a typed handler does not answer another type", #hits, 4)
	h.equals("which gets the not-wired-up reply", callbacks(r, stray)[1] and callbacks(r, stray)[1].type, 4)
end

----------------------------------------------------------------------------
-- deploy warns about commands without handlers, and handlers without commands
----------------------------------------------------------------------------
do
	local r = rig()
	local client = r.client
	-- Builder callbacks inside a table-literal argument are annotated:
	-- there, Luau 1.0.0 does not infer their parameter.
	client:register({
		Commands.slash("role", "Roles")
			:subcommand("add", "Add", function(sub: Commands.Command)
				sub:handle(function() end)
			end)
			:subcommand("remove", "Remove"),
	})
	client:command("pign", function() end)
	client:command("config", function() end)
	client:autocomplete("wether", function() end)
	local lines = capture(function()
		client:deploy({
			Commands.slash("role", "Roles"):subcommand("add", "Add"):subcommand("remove", "Remove"),
			Commands.slash("ping", "Ping"),
			Commands.slash("weather", "Weather"),
			Commands.slash("config", "Config"):group("roles", "Roles", function(group: Commands.Command)
				group:subcommand("set", "Set")
			end),
			Commands.messageCommand("Quote this"),
		})
	end)
	h.equals(
		"a deployed subcommand with no handler is named",
		logged(lines, "warn", '/role remove is deployed but has no handler; users will see "not wired up"'),
		1
	)
	h.equals("a handled one is not", logged(lines, "warn", "/role add is deployed"), 0)
	h.equals("a context menu reads as one", logged(lines, "warn", 'message command "Quote this" is deployed but has no handler'), 1)
	h.equals("a bare-name handler covers its subcommands", logged(lines, "warn", "/config roles set is deployed"), 0)
	h.equals(
		"a handler for a command never deployed is flagged, with a guess",
		logged(lines, "warn", "handler for /pign is registered but no such command was deployed; typo? (did you mean /ping?)"),
		1
	)
	h.equals(
		"autocomplete handlers too",
		logged(lines, "warn", "autocomplete handler for /wether is registered but no such command was deployed"),
		1
	)
	h.equals("/ping itself is still reported as unhandled", logged(lines, "warn", "/ping is deployed but has no handler"), 1)

	local again = capture(function()
		client:deploy({ Commands.slash("ping", "Ping") }, GUILD)
	end)
	h.equals("each mismatch is reported once per client", logged(again, "warn", "/ping is deployed"), 0)
	h.equals("and handlers matched by any earlier deploy stay matched", logged(again, "warn", "handler for /config"), 0)
end

----------------------------------------------------------------------------
-- showErrors: the error's first line in the notice, for development
----------------------------------------------------------------------------
do
	local r = rig({ showErrors = true })
	local client = r.client
	client:command("boom", function()
		error("the widget is missing")
	end)
	client:command("long", function()
		error(string.rep("x", 3000))
	end)
	client:autocomplete("boom", function()
		error("autocomplete broke")
	end)

	local boom = interaction(2, { name = "boom", type = 1 })
	client:_dispatch("INTERACTION_CREATE", boom)
	settle()
	local notice = callbacks(r, boom)[1]
	local content: string = notice and notice.data.content or ""
	h.check("the notice keeps its text", string.find(content, "Something went wrong running that.", 1, true) == 1)
	h.check("and adds the error message", string.find(content, "the widget is missing", 1, true) ~= nil)
	h.check("but not the traceback", string.find(content, "client.luau", 1, true) == nil and select(2, string.gsub(content, "\n", "")) == 3)

	local long = interaction(2, { name = "long", type = 1 })
	client:_dispatch("INTERACTION_CREATE", long)
	settle()
	local longNotice = callbacks(r, long)[1]
	local longContent: string = longNotice and longNotice.data.content or ""
	h.check(`a long error is truncated ({#longContent} chars)`, #longContent > 1500 and #longContent < 1700)

	local auto = interaction(4, { name = "boom", type = 1, options = { { type = 3, name = "q", value = "a", focused = true } } })
	client:_dispatch("INTERACTION_CREATE", auto)
	settle()
	h.equals("autocomplete never gets an error notice", #callbacks(r, auto), 0)

	local quiet = rig()
	quiet.client:command("boom", function()
		error("the widget is missing")
	end)
	local off = interaction(2, { name = "boom", type = 1 })
	quiet.client:_dispatch("INTERACTION_CREATE", off)
	settle()
	local offNotice = callbacks(quiet, off)[1]
	h.equals("off by default", offNotice and offNotice.data.content, "Something went wrong running that.")
end

-- Builders handed straight to deploy bring their handlers with them.
do
	local r = rig()
	local handled = Commands.slash("direct", "Deployed without register"):handle(function(_ix) end)
	local lines = capture(function()
		r.client:deploy({ handled })
	end)
	h.equals(
		"deploy(list) routes the handlers its builders carry",
		logged(lines, "warn", "/direct is deployed but has no handler"),
		0
	)
end

h.finish()
