--!strict
--[[
	The REST transport, driven through a fake transport: bucket locking,
	bucket learning, 429s, retries, error shapes and body encoding.

	Real time passes, so waits are a tenth of a second or two and every
	timing assertion is a LOWER bound with slack -- the limiter's job is to
	not go early, and a loaded machine can only make it later.
]]
local task = require("@lute/task")

local ApiError = require("@discord/error")
local Http = require("@discord/http")
local Log = require("@discord/log")
local Fakes = require("./fakes")
local h = require("./harness")

Log.setLevel("error")

local CH1 = "111111111111111111"
local CH2 = "222222222222222222"
local SLACK = 0.01

type Probe = { done: boolean, ok: boolean, value: any }

--- Starts `fn` on its own task and returns a probe for its outcome.
local function spawn(fn: () -> any): Probe
	local probe: Probe = { done = false, ok = false, value = nil }
	task.spawn(function()
		local ok, value = pcall(fn)
		probe.ok = ok
		probe.value = value
		probe.done = true
	end)
	return probe
end

----------------------------------------------------------------------------
-- One in-flight request per bucket; different buckets run concurrently
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/channels/%d+/messages", { status = 200, body = { id = "1" }, delay = 0.05 })

	local probes: { Probe } = {}
	for _ = 1, 3 do
		table.insert(probes, spawn(function()
			return http:post(`/channels/{CH1}/messages`, { body = { content = "x" } })
		end))
	end
	local other = spawn(function()
		return http:post(`/channels/{CH2}/messages`, { body = { content = "y" } })
	end)
	Fakes.waitUntil(function()
		return probes[1].done and probes[2].done and probes[3].done and other.done
	end)

	local same = rest:find("POST", `/channels/{CH1}/messages`)
	h.equals("all three same-bucket requests went out", #same, 3)
	local serial = true
	for index = 2, #same do
		if same[index].at < same[index - 1].finished then
			serial = false
		end
	end
	h.check("same-bucket requests never overlapped", serial)

	local elsewhere = rest:find("POST", `/channels/{CH2}/messages`)[1]
	h.check(
		"a different channel ran alongside, not queued behind them",
		elsewhere ~= nil and elsewhere.at < same[1].finished
	)
end

----------------------------------------------------------------------------
-- remaining = 0 + reset-after makes the next call wait
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("GET", "/channels/%d+", {
		status = 200,
		body = { id = CH1 },
		headers = {
			["x-ratelimit-bucket"] = "chanbucket",
			["x-ratelimit-limit"] = "1",
			["x-ratelimit-remaining"] = "0",
			["x-ratelimit-reset-after"] = "0.15",
		},
	})
	http:get(`/channels/{CH1}`)
	http:get(`/channels/{CH1}`)
	local calls = rest:find("GET", `/channels/{CH1}`)
	h.check(
		`an exhausted bucket waited out reset-after (gap {string.format("%.3f", calls[2].at - calls[1].finished)}s)`,
		calls[2].at - calls[1].finished >= 0.15 - SLACK
	)

	-- Discord reports the SAME bucket hash for every channel, but each
	-- channel has its own allowance. Keyed by hash alone, channel 2 would
	-- wait out channel 1's reset.
	local before = Fakes.clock()
	http:get(`/channels/{CH2}`)
	local second = rest:find("GET", `/channels/{CH2}`)[1]
	h.check("same hash on another channel did not inherit the wait", second.at - before < 0.1)

	-- Learning the hash moved the state: the route (major parameter
	-- aside, since the hash is shared across them) now maps to it.
	local route = Http._route("GET", `/channels/{CH1}`)
	h.equals("route learned its bucket hash", http.routeToBucket[route], "chanbucket")
	h.equals("the provisional bucket was dropped once learned", http.buckets[Http._routeKey("GET", `/channels/{CH1}`)], nil)
	local learned = http.buckets["chanbucket:channels:" .. CH1]
	h.check("state lives under hash + major parameter", learned ~= nil and learned.remaining <= 0)
end

----------------------------------------------------------------------------
-- Two routes that turn out to share a bucket share its allowance
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	local shared = function(remaining: string): Fakes.Reply
		return {
			status = 200,
			body = {},
			headers = {
				["X-RateLimit-Bucket"] = "shared",
				["X-RateLimit-Limit"] = "2",
				["X-RateLimit-Remaining"] = remaining,
				["X-RateLimit-Reset-After"] = "0.15",
			},
		}
	end
	rest:on("GET", "/channels/%d+/pins", shared("1"))
	rest:on("GET", "/channels/%d+/webhooks", shared("0"))

	http:get(`/channels/{CH1}/pins`)
	http:get(`/channels/{CH1}/webhooks`)
	local started = Fakes.clock()
	http:get(`/channels/{CH1}/pins`)
	h.check(
		"a route mapped onto an exhausted shared bucket waited for it",
		Fakes.clock() - started >= 0.15 - SLACK - 0.02
	)
end

----------------------------------------------------------------------------
-- Per-route 429: retried after retry_after, and the bucket stays shut
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/channels/%d+/messages", function(_call, count): Fakes.Reply?
		if count == 1 then
			return {
				status = 429,
				body = { message = "You are being rate limited.", retry_after = 0.15, global = false },
				headers = { ["x-ratelimit-scope"] = "user" },
			}
		end
		return { status = 200, body = { id = tostring(count) } }
	end)
	local first = spawn(function()
		return http:post(`/channels/{CH1}/messages`, { body = { content = "a" } })
	end)
	-- Queued on the same bucket while the 429 is being handled.
	Fakes.waitUntil(function()
		return #rest.calls >= 1
	end)
	local second = spawn(function()
		return http:post(`/channels/{CH1}/messages`, { body = { content = "b" } })
	end)
	Fakes.waitUntil(function()
		return first.done and second.done
	end)
	h.check("the 429'd request eventually succeeded", first.ok and first.value ~= nil)
	h.check("the queued request succeeded too", second.ok)
	local calls = rest:find("POST", `/channels/{CH1}/messages`)
	h.equals("one 429 plus two successes", #calls, 3)
	local earliest = math.min(calls[2].at, calls[3].at)
	h.check(
		`nothing hit the bucket again before retry_after (gap {string.format("%.3f", earliest - calls[1].finished)}s)`,
		earliest - calls[1].finished >= 0.15 - SLACK
	)
	h.equals("429 counted", http.rateLimitHits, 1)
end

----------------------------------------------------------------------------
-- Global 429 pauses every bucket
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("GET", "/users/@me", function(_call, count): Fakes.Reply?
		if count == 1 then
			return { status = 429, body = { retry_after = 0.2, global = true }, headers = { ["X-RateLimit-Scope"] = "global" } }
		end
		return { status = 200, body = { id = "me" } }
	end)
	rest:on("GET", "/gateway", { status = 200, body = { url = "wss://x" } })

	local me = spawn(function()
		return http:get("/users/@me")
	end)
	Fakes.waitUntil(function()
		return #rest.calls >= 1 and rest.calls[1].finished > 0
	end)
	local pausedAt = rest.calls[1].finished
	local other = spawn(function()
		return http:get("/gateway", { noAuth = true })
	end)
	Fakes.waitUntil(function()
		return me.done and other.done
	end)
	local gatewayCall = rest:find("GET", "/gateway")[1]
	h.check("global 429 was retried", me.ok)
	h.check(
		`an unrelated bucket waited out the global pause (waited {string.format("%.3f", gatewayCall.at - pausedAt)}s)`,
		gatewayCall.at - pausedAt >= 0.2 - SLACK
	)
	h.equals("noAuth sent no Authorization header", gatewayCall.headers["Authorization"], nil)
end

----------------------------------------------------------------------------
-- 5xx: retried with backoff, then an ApiError
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http({ maxRetries = 2 })
	rest:on("GET", "/guilds/%d+", { status = 502, body = "<html>bad gateway</html>" })
	local ok, err = pcall(function()
		return http:get(`/guilds/{CH1}`)
	end)
	h.check("persistent 5xx throws", not ok)
	h.check("the throw is an ApiError", ApiError.is(err))
	h.equals("with the status", (err :: any).status, 502)
	h.equals("after 1 try + maxRetries retries", #rest.calls, 3)

	local http2, rest2 = Fakes.http()
	rest2:on("GET", "/guilds/%d+", function(_call, count): Fakes.Reply?
		return if count < 3 then { status = 503 } else { status = 200, body = { id = CH1 } }
	end)
	local guild = http2:get(`/guilds/{CH1}`)
	h.equals("transient 5xx recovers", guild.id, CH1)
end

----------------------------------------------------------------------------
-- Transport failures: GET retries, POST does not
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("GET", "/users/@me", function(_call, count): Fakes.Reply?
		return if count < 3 then { throw = "connection reset" } else { status = 200, body = { id = "me" } }
	end)
	h.equals("GET survived two transport failures", http:get("/users/@me").id, "me")
	h.equals("GET was attempted three times", #rest.calls, 3)

	local http2, rest2 = Fakes.http()
	rest2:on("POST", "/channels/%d+/messages", { throw = "connection reset" })
	local ok, err = pcall(function()
		return http2:post(`/channels/{CH1}/messages`, { body = { content = "once" } })
	end)
	h.check("POST transport failure throws", not ok and ApiError.is(err))
	h.equals("POST was not retried (it could double-post)", #rest2.calls, 1)
	h.check("the error names the transport failure", string.find(tostring(err), "connection reset", 1, true) ~= nil)
end

----------------------------------------------------------------------------
-- 4xx: ApiError with field errors, no retry
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/channels/%d+/messages", {
		status = 400,
		body = {
			code = 50035,
			message = "Invalid Form Body",
			errors = { content = { _errors = { { code = "BASE_TYPE_MAX_LENGTH", message = "Must be 2000 or fewer in length." } } } },
		},
	})
	local ok, err = pcall(function()
		return http:post(`/channels/{CH1}/messages`, { body = { content = string.rep("x", 2001) } })
	end)
	h.check("4xx throws an ApiError", not ok and ApiError.is(err))
	local apiError = err :: ApiError.ApiError
	h.equals("status", apiError.status, 400)
	h.equals("Discord's code", apiError.code, 50035)
	h.equals("field errors flattened", ApiError.fieldErrors(apiError)[1], "content: Must be 2000 or fewer in length.")
	h.equals("4xx not retried", #rest.calls, 1)
end

----------------------------------------------------------------------------
-- 204, headers, auth, query
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("DELETE", "/channels/%d+/messages/%d+", { status = 204 })
	h.equals("204 returns nil", http:delete(`/channels/{CH1}/messages/{CH2}`), nil)
	local call = rest.calls[1]
	h.equals("Authorization carries the bot token", call.headers["Authorization"], "Bot TOKEN")
	h.check("User-Agent is set", call.headers["User-Agent"] ~= nil)

	http:get(`/channels/{CH1}/messages`, { query = { limit = 5, before = CH2 } })
	h.equals("query string is built and sorted", rest.calls[2].query, `?before={CH2}&limit=5`)

	h.equals("header lookup ignores case", Http._header({ ["X-RateLimit-Bucket"] = "abc" }, "x-ratelimit-bucket"), "abc")

	-- Audit-log reasons travel in a header, where a newline or a non-ASCII
	-- byte is a protocol error.
	http:put(`/guilds/{CH1}/bans/{CH2}`, { reason = "spam: bad\nlinks \u{2713}" })
	h.equals(
		"audit-log reason is percent-encoded",
		rest.calls[3].headers["X-Audit-Log-Reason"],
		"spam%3A%20bad%0Alinks%20%E2%9C%93"
	)
	h.equals("no body, no Content-Type", rest.calls[3].headers["Content-Type"], nil)
	http:post(`/channels/{CH1}/messages`, { body = { content = "hi" } })
	h.equals("a JSON body is labelled as such", rest.calls[4].headers["Content-Type"], "application/json")
	h.equals("and encoded", rest.calls[4].json.content, "hi")
end

----------------------------------------------------------------------------
-- Multipart: payload_json + files[n] + attachments
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("PATCH", "/channels/%d+/messages/%d+", { status = 200, body = {} })
	http:patch(`/channels/{CH1}/messages/{CH2}`, {
		body = {
			content = "files",
			-- An existing attachment to keep, and metadata for new file 1.
			attachments = { { id = "333333333333333333" }, { id = 1, description = "second file" } },
		},
		files = {
			{ name = "a.txt", data = "hello" },
			{ name = 'we"ird\n.png', data = buffer.fromstring("PNG"), contentType = "image/png" },
			{ name = "back\\slash.txt", data = "c" },
		},
	})
	local call = rest.calls[1]
	local contentType = call.headers["Content-Type"]
	local boundary = string.match(contentType, "^multipart/form%-data; boundary=(.+)$")
	h.check("multipart content type names a boundary", boundary ~= nil)
	local body = call.body :: string
	local b = boundary :: string
	h.check("body ends with the closing boundary", string.sub(body, -(#b + 6)) == `--{b}--\r\n`)
	h.check("payload_json part present", string.find(body, 'name="payload_json"\r\nContent-Type: application/json', 1, true) ~= nil)
	h.check("files[0] part present", string.find(body, 'name="files[0]"; filename="a.txt"\r\nContent-Type: application/octet-stream\r\n\r\nhello\r\n', 1, true) ~= nil)
	h.check("files[1] part with its own type, buffer data", string.find(body, "Content-Type: image/png\r\n\r\nPNG\r\n", 1, true) ~= nil)
	h.check("a quote or newline in a filename cannot break the header", string.find(body, 'filename="we%22ird.png"', 1, true) ~= nil)
	h.check("a backslash in a filename is escaped too", string.find(body, 'filename="back%5Cslash.txt"', 1, true) ~= nil)

	local jsonText = string.match(body, 'name="payload_json"\r\nContent%-Type: application/json\r\n\r\n(.-)\r\n%-%-')
	local Json = require("@discord/json")
	local payload = Json.decode(jsonText :: string)
	local ids = {}
	for _, entry in payload.attachments do
		ids[tostring(entry.id)] = entry
	end
	h.check("existing attachment kept", ids["333333333333333333"] ~= nil)
	h.equals("new file 0 has id 0 and its filename", ids["0"] and ids["0"].filename, "a.txt")
	h.equals("caller metadata merged into new file 1", ids["1"] and ids["1"].description, "second file")
	h.equals("new file 2 has id 2", ids["2"] and ids["2"].filename, "back\\slash.txt")
	h.equals("one entry per file plus the kept one, no duplicates", #payload.attachments, 4)
	h.equals("content preserved", payload.content, "files")
end

----------------------------------------------------------------------------
-- Plain form (Create Guild Sticker): fields + named files, no payload_json
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/guilds/%d+/stickers", { status = 200, body = { id = "s1" } })
	http:post(`/guilds/{CH1}/stickers`, {
		form = {
			fields = { name = "tofu", description = "a block", tags = "cube" },
			files = { file = { name = "tofu.png", data = "PNGDATA", contentType = "image/png" } },
		},
		reason = "new sticker",
	})
	local call = rest.calls[1]
	local body = call.body :: string
	h.check("form uses multipart", string.find(call.headers["Content-Type"], "multipart/form-data; boundary=", 1, true) == 1)
	h.check("text field part", string.find(body, 'name="name"\r\n\r\ntofu\r\n', 1, true) ~= nil)
	h.check("tags field part", string.find(body, 'name="tags"\r\n\r\ncube\r\n', 1, true) ~= nil)
	h.check("file part named by its key", string.find(body, 'name="file"; filename="tofu.png"\r\nContent-Type: image/png\r\n\r\nPNGDATA\r\n', 1, true) ~= nil)
	h.check("no payload_json in a plain form", string.find(body, "payload_json", 1, true) == nil)
	h.check("no attachments array either", string.find(body, "attachments", 1, true) == nil)

	h.throws("form + body is rejected", "cannot be combined", function()
		http:post(`/guilds/{CH1}/stickers`, { form = { fields = { name = "x" } }, body = { name = "x" } })
	end)
	h.throws("form + files is rejected", "cannot be combined", function()
		http:post(`/guilds/{CH1}/stickers`, { form = { fields = {} }, files = { { name = "a", data = "b" } } })
	end)
end

----------------------------------------------------------------------------
-- Interaction tokens are not part of the route, and buckets stay bounded
----------------------------------------------------------------------------
local Json = require("@discord/json")
local Util = require("@discord/util")
local APP = "900000000000000001"

local function count(map: { [string]: any }): number
	local total = 0
	for _ in map do
		total += 1
	end
	return total
end

do
	h.equals(
		"an interaction callback's token is templated out of the route",
		Http._routeKey("POST", "/interactions/700000000000000001/aW50ZXJhY3Rpb246dG9rZW4/callback"),
		"POST /interactions/:id/:token/callback:interactions:700000000000000001"
	)
	h.equals(
		"a follow-up is limited per webhook id plus token",
		Http._routeKey("POST", `/webhooks/{APP}/tokenA`),
		`POST /webhooks/:id/:token:webhooks:{APP}:tokenA`
	)
	h.equals(
		"a webhook route without a token is limited per webhook id",
		Http._routeKey("GET", `/webhooks/{APP}`),
		`GET /webhooks/:id:webhooks:{APP}`
	)

	local http, rest = Fakes.http()
	rest:on("POST", "/interactions/%d+/[^/]+/callback", {
		status = 204,
		headers = {
			["x-ratelimit-bucket"] = "callbacks",
			["x-ratelimit-limit"] = "5",
			["x-ratelimit-remaining"] = "4",
			["x-ratelimit-reset-after"] = "0.001",
		},
	})
	rest:on("POST", "/webhooks/%d+/[^/]+", { status = 200, body = { id = "f" } })
	for index = 1, 1000 do
		http:post(`/interactions/{700000000000000000 + index}/tok{index}/callback`, { body = { type = 4 } })
		http:post(`/webhooks/{APP}/tok{index}`, { body = { content = "x" }, interaction = true })
		if index % 250 == 0 then
			task.wait(0.002) -- let the short resets pass, as real time would
		end
	end
	h.check(`2000 interaction requests leave a bounded bucket table ({count(http.buckets)})`, count(http.buckets) <= 600)
	h.check(`and a bounded route map ({count(http.routeToBucket)})`, count(http.routeToBucket) <= 2)
end

-- Pruning never drops a bucket that is still limiting something.
do
	local http, rest = Fakes.http()
	rest:on("GET", "/channels/%d+", {
		status = 200,
		body = {},
		headers = {
			["x-ratelimit-bucket"] = "chan",
			["x-ratelimit-limit"] = "1",
			["x-ratelimit-remaining"] = "0",
			["x-ratelimit-reset-after"] = "0.3",
		},
	})
	rest:on("POST", "/interactions/%d+/[^/]+/callback", { status = 204 })
	http:get(`/channels/{CH1}`)
	for index = 1, 600 do
		http:post(`/interactions/{700000000000000000 + index}/t{index}/callback`, { body = { type = 6 } })
	end
	local held = http.buckets["chan:channels:" .. CH1]
	h.check("an exhausted bucket survives a sweep", held ~= nil and held.remaining <= 0)
	local before = Fakes.clock()
	http:get(`/channels/{CH1}`)
	h.check("and still makes the next call wait", Fakes.clock() - before >= 0.2)
end

----------------------------------------------------------------------------
-- Interaction endpoints are outside the global limit
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/interactions/%d+/[^/]+/callback", { status = 204 })
	rest:on("POST", "/webhooks/%d+/[^/]+", { status = 200, body = { id = "f" } })
	rest:on("POST", "/channels/%d+/messages", { status = 200, body = { id = "m" } })
	-- A global pause is in force, as after a global 429.
	http.globalResetAt = Util.now()
	http.globalWait = 0.3
	local started = Fakes.clock()
	http:post("/interactions/700000000000000001/tok/callback", { body = { type = 5 }, noAuth = true })
	h.check("an interaction callback is not held by a global pause", Fakes.clock() - started < 0.1)
	http:post(`/webhooks/{APP}/tok`, { body = { content = "x" }, noAuth = true, interaction = true })
	h.check("nor is an interaction follow-up", Fakes.clock() - started < 0.1)
	http:post(`/channels/{CH1}/messages`, { body = { content = "x" } })
	h.check("but an ordinary route is", Fakes.clock() - started >= 0.3 - SLACK)

	-- Nor by the proactive per-second window.
	local http2, rest2 = Fakes.http()
	rest2:on("POST", "/interactions/%d+/[^/]+/callback", { status = 204 })
	http2.windowStart = Util.now()
	http2.windowCount = 1000
	local began = Fakes.clock()
	http2:post("/interactions/700000000000000002/tok/callback", { body = { type = 5 }, noAuth = true })
	h.check("a callback does not queue behind a REST burst's window", Fakes.clock() - began < 0.1)
	h.equals("and does not spend the window either", http2.windowCount, 1000)
end

-- Follow-ups for different interactions do not share bucket state.
do
	local http, rest = Fakes.http()
	rest:on("POST", "/webhooks/%d+/[^/]+", {
		status = 200,
		body = { id = "f" },
		headers = {
			["x-ratelimit-bucket"] = "wh",
			["x-ratelimit-limit"] = "1",
			["x-ratelimit-remaining"] = "0",
			["x-ratelimit-reset-after"] = "0.3",
		},
	})
	http:post(`/webhooks/{APP}/tokenA`, { body = { content = "a" }, interaction = true })
	local started = Fakes.clock()
	http:post(`/webhooks/{APP}/tokenB`, { body = { content = "b" }, interaction = true })
	h.check("interaction B's follow-up does not wait out interaction A's bucket", Fakes.clock() - started < 0.1)
	http:post(`/webhooks/{APP}/tokenA`, { body = { content = "a2" }, interaction = true })
	h.check("but A's own next follow-up does", Fakes.clock() - started >= 0.3 - SLACK)
end

----------------------------------------------------------------------------
-- Multipart: attachments live in the nested message object
----------------------------------------------------------------------------
local function payloadJson(call: Fakes.Call): (any, string?)
	local text = string.match(call.body :: string, 'name="payload_json"\r\nContent%-Type: application/json\r\n\r\n(.-)\r\n%-%-')
	return Json.decode(text :: string), text
end

do
	local http, rest = Fakes.http()
	rest:on("POST", "/interactions/%d+/[^/]+/callback", { status = 204 })
	http:post("/interactions/700000000000000001/tok/callback", {
		body = { type = 4, data = { content = "pic", attachments = { { id = 0, description = "alt from caller" } } } },
		files = { { name = "a.png", data = "A" }, { name = "b.png", data = "B", description = "alt for b" } },
		attachmentsPath = "data",
	})
	local payload = payloadJson(rest.calls[1])
	h.equals("no attachments at the top level of a callback", payload.attachments, nil)
	local byId = {}
	for _, entry in payload.data.attachments or {} do
		byId[tostring(entry.id)] = entry
	end
	h.equals("the caller's metadata is merged into data.attachments", byId["0"] and byId["0"].description, "alt from caller")
	h.equals("a file's own description reaches data.attachments", byId["1"] and byId["1"].description, "alt for b")
	h.equals("one entry per file", #(payload.data.attachments or {}), 2)
	h.equals("type is untouched", payload.type, 4)

	rest:on("POST", "/channels/%d+/threads", { status = 200, body = { id = "t" } })
	local message = { content = "first post" }
	http:post(`/channels/{CH1}/threads`, {
		body = { name = "post", message = message },
		files = { { name = "c.txt", data = "C", description = "notes" } },
		attachmentsPath = "message",
	})
	local post = payloadJson(rest.calls[2])
	h.equals("a forum post's attachments go inside message", post.message.attachments and post.message.attachments[1].description, "notes")
	h.equals("and not at the top level", post.attachments, nil)
	h.equals("the caller's nested table was not modified", (message :: any).attachments, nil)

	-- A callback with files but no data still gets somewhere to put them.
	http:post("/interactions/700000000000000002/tok/callback", {
		body = { type = 7 },
		files = { { name = "d.txt", data = "D" } },
		attachmentsPath = "data",
	})
	local bare = payloadJson(rest.calls[3])
	h.equals("a missing nested object is created for the attachments", bare.data and bare.data.attachments[1].filename, "d.txt")
end

----------------------------------------------------------------------------
-- PATCH with new files: append unless told otherwise
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("PATCH", "/channels/%d+/messages/%d+", { status = 200, body = {} })

	-- No keep-list, no metadata: omit attachments so Discord appends.
	http:patch(`/channels/{CH1}/messages/{CH2}`, { body = { content = "more" }, files = { { name = "new.txt", data = "n" } } })
	local plain = payloadJson(rest.calls[1])
	h.equals("a PATCH that only adds files sends no attachments array", plain.attachments, nil)
	h.equals("and keeps the rest of the body", plain.content, "more")
	h.check("the file part still goes out", string.find(rest.calls[1].body :: string, 'name="files[0]"; filename="new.txt"', 1, true) ~= nil)

	-- A keep-list from the caller: merged with the new files, as before.
	http:patch(`/channels/{CH1}/messages/{CH2}`, {
		body = { attachments = { { id = "333333333333333333" } } },
		files = { { name = "new.txt", data = "n" } },
	})
	local kept = payloadJson(rest.calls[2])
	h.equals("a caller keep-list is merged with the new files", kept.attachments and #kept.attachments, 2)

	-- A description with no keep-list: the array is required to carry it.
	http:patch(`/channels/{CH1}/messages/{CH2}`, { body = {}, files = { { name = "alt.png", data = "p", description = "alt" } } })
	local described = payloadJson(rest.calls[3])
	h.equals("a described file still sends the array it needs", described.attachments and described.attachments[1].description, "alt")

	-- A PATCH whose body is only files must still send an object.
	local _, text = payloadJson(rest.calls[1])
	local http2, rest2 = Fakes.http()
	rest2:on("PATCH", "/channels/%d+/messages/%d+", { status = 200, body = {} })
	http2:patch(`/channels/{CH1}/messages/{CH2}`, { body = {}, files = { { name = "x.txt", data = "x" } } })
	local _, emptyText = payloadJson(rest2.calls[1])
	h.equals("an empty payload_json is an object, not an array", emptyText, "{}")
	h.check("(sanity) a non-empty one is an object too", string.sub(text or "", 1, 1) == "{")

	-- POST keeps sending the array: there is nothing to append to.
	rest:on("POST", "/channels/%d+/messages", { status = 200, body = {} })
	http:post(`/channels/{CH1}/messages`, { body = { content = "new" }, files = { { name = "p.txt", data = "p" } } })
	local created = payloadJson(rest.calls[4])
	h.equals("a POST still lists its files in attachments", created.attachments and #created.attachments, 1)
end

----------------------------------------------------------------------------
-- An empty JSON body is an object unless the route takes a list
----------------------------------------------------------------------------
do
	local http, rest = Fakes.http()
	rest:on("POST", "/guilds/%d+/prune", { status = 200, body = { pruned = 0 } })
	rest:on("PUT", "/applications/%d+/commands", { status = 200, body = {} })
	http:post(`/guilds/{CH1}/prune`, { body = {} })
	h.equals("an empty table body is sent as {}", rest.calls[1].body, "{}")
	http:put(`/applications/{APP}/commands`, { body = {}, list = true })
	h.equals("a list route's empty body stays []", rest.calls[2].body, "[]")
	http:post(`/guilds/{CH1}/prune`, { body = { days = 7 } })
	h.equals("a non-empty body is untouched", rest.calls[3].json.days, 7)
end

h.finish()
