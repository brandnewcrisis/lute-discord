--!strict
--[[
	Test doubles for the network layer: a scripted REST transport and a fake
	gateway socket. Not a `.test.luau`, so the runner skips it.

	Both record everything they are handed with a timestamp, because the
	behaviour under test -- rate limiting, backoff, heartbeating -- is about
	WHEN things are sent as much as what.
]]
local task = require("@lute/task")

local Gateway = require("@discord/gateway")
local Http = require("@discord/http")
local Json = require("@discord/json")
local Util = require("@discord/util")

local Fakes = {}

local epoch = Util.now()

--- Seconds since this module loaded. One clock for every fake, so
--- timestamps from the transport and the socket compare directly.
function Fakes.clock(): number
	return Util.since(epoch)
end

--- Polls until `condition` holds or `timeout` passes. Returns whether it held.
function Fakes.waitUntil(condition: () -> boolean, timeout: number?): boolean
	local limit = timeout or 2
	local started = Util.now()
	while not condition() do
		if Util.since(started) >= limit then
			return false
		end
		task.wait(0.005)
	end
	return true
end

----------------------------------------------------------------------------
-- REST
----------------------------------------------------------------------------

export type Call = {
	method: string,
	url: string,
	--- The URL minus the base and query string.
	path: string,
	query: string,
	body: string?,
	--- `body` decoded as JSON, when it is JSON.
	json: any,
	headers: { [string]: string },
	at: number,
	--- When the transport returned; `at` plus the scripted delay.
	finished: number,
}

--- What a responder returns. `body` may be a table (JSON-encoded) or a
--- string. `delay` simulates latency; `throw` simulates a transport failure.
export type Reply = {
	status: number?,
	body: any?,
	headers: { [string]: string }?,
	delay: number?,
	throw: string?,
}

export type Responder = (call: Call, count: number) -> Reply?

type Route = { method: string, pattern: string, respond: Responder, count: number }

export type Rest = {
	calls: { Call },
	routes: { Route },
	transport: Http.Transport,
	--- Registers a responder for `method` + a Lua pattern anchored on the
	--- path. Later registrations win, so a test can override a default.
	on: (self: Rest, method: string, pattern: string, respond: Responder | Reply) -> (),
	--- Calls whose method matches and whose path matches `pattern`.
	find: (self: Rest, method: string?, pattern: string) -> { Call },
}

local BASE = "https://discord.test/api"

function Fakes.rest(): Rest
	local self = {
		calls = {} :: { Call },
		routes = {} :: { Route },
	} :: Rest

	function self.on(rest: Rest, method: string, pattern: string, respond: Responder | Reply)
		local fn: Responder = if type(respond) == "function"
			then respond
			else function(): Reply?
				return respond :: Reply
			end
		table.insert(rest.routes, 1, { method = method, pattern = pattern, respond = fn, count = 0 })
	end

	function self.find(rest: Rest, method: string?, pattern: string): { Call }
		local out = {}
		for _, call in rest.calls do
			if (method == nil or call.method == method) and string.match(call.path, "^" .. pattern .. "$") ~= nil then
				table.insert(out, call)
			end
		end
		return out
	end

	self.transport = function(url: string, request: Http.TransportRequest): Http.TransportResponse
		local rest = string.sub(url, #BASE + 1)
		local path, query = string.match(rest, "^([^?]*)(.*)$")
		local decoded: any = nil
		local first = string.sub(request.body or "", 1, 1)
		if first == "{" or first == "[" then
			decoded = Json.decode(request.body :: string)
		end
		local call: Call = {
			method = request.method,
			url = url,
			path = path or rest,
			query = query or "",
			body = request.body,
			json = decoded,
			headers = request.headers,
			at = Fakes.clock(),
			finished = 0,
		}
		table.insert(self.calls, call)

		local reply: Reply? = nil
		for _, route in self.routes do
			if
				(route.method == "*" or route.method == request.method)
				and string.match(call.path, "^" .. route.pattern .. "$") ~= nil
			then
				route.count += 1
				reply = route.respond(call, route.count)
				break
			end
		end
		local r: Reply = reply or { status = 204 }
		if r.delay ~= nil and r.delay > 0 then
			task.wait(r.delay)
		end
		call.finished = Fakes.clock()
		if r.throw ~= nil then
			error(r.throw, 0)
		end
		local body = r.body
		local text = if body == nil then "" elseif type(body) == "string" then body else Json.encode(body)
		return { status = r.status or 200, headers = r.headers or {}, body = text }
	end

	return self
end

--- An Http wired to a fresh fake transport, with fast retries.
function Fakes.http(options: Http.HttpOptions?): (Http.Http, Rest)
	local rest = Fakes.rest()
	local opts: Http.HttpOptions = options or {}
	return Http.new("TOKEN", {
		transport = rest.transport,
		baseUrl = BASE,
		maxRetries = opts.maxRetries,
		backoffBase = opts.backoffBase or 0.01,
		backoffCap = opts.backoffCap or 0.02,
	}),
		rest
end

Fakes.BASE = BASE

----------------------------------------------------------------------------
-- Gateway socket
----------------------------------------------------------------------------

export type Frame = { op: number, d: any, at: number }

export type FakeSocket = {
	url: string,
	--- `Fakes.clock()` when the client dialled it.
	openedAt: number,
	handlers: Gateway.SocketHandlers,
	sent: { Frame },
	closedByClient: boolean,
	--- False while `connect` is still yielding through its handshake.
	dialled: boolean,
	send: (self: FakeSocket, data: string) -> (),
	close: (self: FakeSocket) -> (),
	--- Delivers a server frame, as JSON, to the client's `onmessage`.
	push: (self: FakeSocket, payload: { [string]: any }) -> (),
	hello: (self: FakeSocket, intervalMs: number) -> (),
	dispatch: (self: FakeSocket, event: string, data: any, seq: number) -> (),
	--- Closes from the server side with a code, as Discord does.
	serverClose: (self: FakeSocket, code: number, reason: string?) -> (),
	--- Sent frames with this opcode.
	ofOp: (self: FakeSocket, op: number) -> { Frame },
}

export type Connector = {
	sockets: { FakeSocket },
	connect: Gateway.Connect,
	--- What `close()` from the client reports back through `onclose`, if
	--- anything. Real runtimes differ; default is a late 1000, delivered on
	--- the next scheduler cycle, which is the case most likely to confuse a
	--- shard that has already moved on to its next socket.
	closeEcho: number?,
	--- Make the next N `connect` calls throw.
	failNext: number,
	--[[
		Seconds `connect` yields before returning the handle, as Lute's real
		`websocket()` does through the handshake. The socket is registered
		(and can receive server frames) before the yield, so a test can
		deliver HELLO or call `send` while the dial is still in progress.
		`dialDelays[n]` overrides it for the n-th socket.
	]]
	dialDelay: number,
	dialDelays: { [number]: number },
	latest: (self: Connector) -> FakeSocket?,
}

function Fakes.connector(): Connector
	local connector = {
		sockets = {} :: { FakeSocket },
		closeEcho = 1000 :: number?,
		failNext = 0,
		dialDelay = 0,
		dialDelays = {},
	} :: Connector

	function connector.latest(c: Connector): FakeSocket?
		return c.sockets[#c.sockets]
	end

	connector.connect = function(url: string, handlers: Gateway.SocketHandlers): Gateway.Socket
		if connector.failNext > 0 then
			connector.failNext -= 1
			error("connection refused", 0)
		end
		local socket = {
			url = url,
			openedAt = Fakes.clock(),
			handlers = handlers,
			sent = {} :: { Frame },
			closedByClient = false,
			dialled = false,
		} :: FakeSocket

		function socket.send(s: FakeSocket, data: string)
			local decoded = Json.decode(data)
			table.insert(s.sent, { op = decoded.op, d = decoded.d, at = Fakes.clock() })
		end

		function socket.close(s: FakeSocket)
			if s.closedByClient then
				return
			end
			s.closedByClient = true
			local echo = connector.closeEcho
			local onclose = s.handlers.onclose
			if echo ~= nil and onclose ~= nil then
				task.defer(onclose, echo, "")
			end
		end

		function socket.push(s: FakeSocket, payload: { [string]: any })
			local onmessage = s.handlers.onmessage
			if onmessage ~= nil then
				onmessage(Json.encode(payload))
			end
		end

		function socket.hello(s: FakeSocket, intervalMs: number)
			s:push({ op = 10, d = { heartbeat_interval = intervalMs } })
		end

		function socket.dispatch(s: FakeSocket, event: string, data: any, seq: number)
			s:push({ op = 0, t = event, s = seq, d = data })
		end

		function socket.serverClose(s: FakeSocket, code: number, reason: string?)
			local onclose = s.handlers.onclose
			if onclose ~= nil then
				onclose(code, reason or "")
			end
		end

		function socket.ofOp(s: FakeSocket, op: number): { Frame }
			local out = {}
			for _, frame in s.sent do
				if frame.op == op then
					table.insert(out, frame)
				end
			end
			return out
		end

		table.insert(connector.sockets, socket)
		local delay = connector.dialDelays[#connector.sockets] or connector.dialDelay
		if delay > 0 then
			task.wait(delay)
		end
		socket.dialled = true
		return (socket :: any) :: Gateway.Socket
	end

	return connector
end

--- A READY payload for `sessionId`.
function Fakes.ready(sessionId: string, resumeUrl: string?): any
	return {
		v = 10,
		user = { id = "900000000000000001", username = "tofu", bot = true },
		guilds = {},
		session_id = sessionId,
		resume_gateway_url = resumeUrl or "wss://resume.discord.test",
		application = { id = "900000000000000001", flags = 0 },
	}
end

return Fakes
