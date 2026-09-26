--!strict
--[[
	The REST transport: rate limiting, retries, multipart, audit reasons.

	Discord's limiter is per-BUCKET, and a bucket is not a route -- several
	routes share one, and one route splits into several by "major parameter"
	(the channel, guild or webhook id in the path). Discord tells you which
	bucket a request landed in only in the RESPONSE, via `x-ratelimit-bucket`,
	so the mapping has to be learned. Until a route's bucket is known its
	route key stands in as a provisional bucket, which errs toward
	over-serialising rather than toward a 429.

	Requests to the same bucket are executed one at a time and the lock is
	held across the call, so the headers from request N are applied before
	request N+1 decides whether to wait. Different buckets run concurrently.

	Everything here uses monotonic time. `x-ratelimit-reset` is a wall-clock
	unix timestamp and comparing it against a local clock that is a few
	seconds off produces either constant 429s or a bot that sleeps forever --
	so `x-ratelimit-reset-after`, a duration, is used instead.
]]
local net = require("@std/net")
local task = require("@lute/task")

local Const = require("@discord/const")
local Json = require("@discord/json")
local Log = require("@discord/log")
local Types = require("@discord/types")
local Util = require("@discord/util")
local ApiError = require("@discord/error")

type Bucket = {
	limit: number,
	remaining: number,
	resetAt: Util.Instant?,
	resetAfter: number,
	locked: boolean,
}

--- Re-exported so `Http.File` keeps working; the shape lives in
--- `@discord/types` because payloads have to name it too.
export type File = Types.File

export type RequestOptions = {
	--[[
		Becomes `?a=1&b=2`. Values are stringified; nils are skipped.

		`any` rather than an indexer type because every caller passes a closed
		record -- `{ limit: number?, before: Snowflake? }` and so on -- and
		Luau does not admit those as subtypes of `{ [string]: any }`. The
		precision lives one layer up, on each route in `@discord/api`, which
		is where a wrong query key is worth catching.
	]]
	query: any?,
	--[[
		Serialised as the JSON body, or as the `payload_json` part when
		`files` is set.

		An empty Luau table is ambiguous -- `{}` and `[]` are the same value
		-- and `@std/json` writes it as `[]`. Nearly every Discord body is an
		object, and a patch whose optional fields are all nil is exactly
		that empty table, so an empty top-level body is sent as `{}`. The
		few routes whose body is a LIST set `list`.
	]]
	body: any?,
	--- The body is a JSON array (bulk command overwrite, position lists),
	--- so an empty one must go out as `[]`.
	list: boolean?,
	files: { File }?,
	--[[
		Where the message that owns the uploads sits inside `body`, when it
		is not the body itself: `"data"` for an interaction callback
		(`{type, data}`), `"message"` for a forum post (`{name, message}`).
		Discord reads `attachments` -- and with it each file's description
		-- from that object, and ignores one at the top level.
	]]
	attachmentsPath: string?,
	--[[
		A plain multipart form, for the few routes that take one instead of
		`payload_json` -- Create Guild Sticker wants `name`, `description`,
		`tags` and a part called `file`, and rejects a JSON part. Each field
		is a text part and each file a part named by its key. Mutually
		exclusive with `body` and `files`.
	]]
	form: { fields: { [string]: string }?, files: { [string]: File }? }?,
	reason: string?,
	headers: { [string]: string }?,
	--- Skip the Authorization header (interaction callbacks, public routes).
	noAuth: boolean?,
	--- Overrides the default retry count for this call.
	retries: number?,
	--[[
		An interaction endpoint: the callback, or a webhook route under the
		application id and an interaction token (original response and
		follow-ups). Discord exempts these from the global rate limit, so
		they skip both a global 429 pause and the proactive per-second
		window -- a callback queued behind a REST burst can miss its
		3-second deadline. `/interactions/...` paths are recognised without
		it; the webhook-shaped ones cannot be told from a plain webhook by
		path, so `@discord/api` sets it.
	]]
	interaction: boolean?,
}

--- What a transport is handed: everything `net.request` takes.
export type TransportRequest = {
	method: string,
	body: string?,
	headers: { [string]: string },
}

--- What a transport must return. Header names may arrive in any case.
export type TransportResponse = {
	status: number,
	headers: { [string]: string },
	body: string,
}

--[[
	The function that actually puts a request on the wire.

	Defaults to `net.request`. Swapping it is how the test suite drives the
	rate limiter and the retry loop without a network, and how a bot can
	route REST traffic through a proxy. It may yield, and it should THROW on
	a transport failure (DNS, reset, TLS) rather than return a fake status --
	a throw is what marks the request as safe or unsafe to retry.
]]
export type Transport = (url: string, request: TransportRequest) -> TransportResponse

export type HttpOptions = {
	userAgent: string?,
	maxRetries: number?,
	transport: Transport?,
	--- Overrides `Const.API_BASE`, e.g. for a local mock server.
	baseUrl: string?,
	--- Retry backoff for 5xx and transport failures: full jitter between 0
	--- and `min(cap, base * 2^attempt)` seconds. Defaults 0.5 and 10. The
	--- test suite shrinks these; a bot has little reason to.
	backoffBase: number?,
	backoffCap: number?,
}

local Http = {}
Http.__index = Http

export type Http = typeof(setmetatable(
	{} :: {
		token: string,
		userAgent: string,
		maxRetries: number,
		transport: Transport,
		baseUrl: string,
		backoffBase: number,
		backoffCap: number,
		buckets: { [string]: Bucket },
		--- Entries in `buckets`; Luau tables do not count themselves.
		bucketCount: number,
		--- Sweep `buckets` once `bucketCount` passes this.
		sweepAt: number,
		--- Route (without major parameter) -> learned bucket hash.
		routeToBucket: { [string]: string },
		globalResetAt: Util.Instant?,
		globalWait: number,
		--- Rolling count for the 50-requests-per-second global ceiling.
		windowStart: Util.Instant,
		windowCount: number,
		requestCount: number,
		rateLimitHits: number,
	},
	{} :: typeof(Http)
))

-- Discord's global ceiling is 50/s. Staying under it proactively is cheaper
-- than discovering it, because a global 429 pauses every bucket at once.
local GLOBAL_PER_SECOND = 45

-- The bucket table is swept for spent entries once it grows past this, and
-- then past twice what survived the last sweep, so the cost stays O(1) per
-- request however many buckets are live.
local SWEEP_MIN = 256

local ID_PATTERN = "%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+"

--[[
	The key a request is limited under: its route plus its major parameter.

	Ids are collapsed to `:id` so `/channels/1/messages/2` and
	`/channels/1/messages/3` share a route. The "major parameter" -- the
	top-level resource Discord limits per object -- is appended literally:
	the channel or guild id, and for webhooks the id PLUS the token, since
	Discord keys webhook limits by both. Interaction follow-ups are webhook
	routes under the application id, so each interaction token gets its own
	bucket state rather than every follow-up of the bot sharing one.

	An interaction callback is keyed by its interaction id. Discord does
	not list interactions as a top-level resource, but each token accepts
	exactly one callback, and the bucket lock is held across the call: one
	shared key would serialise every callback of the bot behind the slowest
	in flight, and under a burst the last in line misses the 3-second
	deadline. A per-interaction key costs a bucket per interaction, which
	the sweep in `Http.request` reclaims.

	Deleting a message is special-cased: Discord gives it a separate, much
	tighter bucket than other operations on the same route, and folding the
	two together makes a purge command 429 immediately.
]]
--- The major parameter of a path, as `:channels:123`, or "" when it has none.
local function majorOf(path: string): string
	local majorType, majorId, rest = string.match(path, "^/(%a+)/(%d+)(.*)$")
	if majorType == "channels" or majorType == "guilds" or majorType == "interactions" then
		return `:{majorType}:{majorId}`
	elseif majorType == "webhooks" then
		local token = string.match(rest :: string, "^/([^/?]+)")
		return if token ~= nil then `:webhooks:{majorId}:{token}` else `:webhooks:{majorId}`
	end
	return ""
end

--- The route alone, without the major parameter. Discord reports one bucket
--- hash for a route whatever its major parameter, so this is what the
--- learned hash is filed under -- and it is bounded by the number of routes.
local function routeOf(method: string, path: string): string
	local template = string.gsub(path, ID_PATTERN, ":id")
	-- Reaction emoji are arbitrary text (and custom ones carry an id).
	template = string.gsub(template, "/reactions/[^/]+", "/reactions/:emoji")
	-- Interaction and webhook tokens are unbounded strings, never ids; left
	-- in, every interaction would mint a new route.
	template = string.gsub(template, "(/webhooks/:id/)[^/]+", "%1:token")
	template = string.gsub(template, "^/interactions/[^/]+/[^/]+", "/interactions/:id/:token")

	local prefix = if method == "DELETE" and string.find(template, "/messages/:id$") ~= nil
		then "DELETE_MESSAGE "
		else method .. " "
	return prefix .. template
end

local function routeKey(method: string, path: string): string
	return routeOf(method, path) .. majorOf(path)
end

local function header(headers: { [string]: string }, name: string): string?
	-- Header casing is whatever the server sent; Cloudflare and Discord
	-- disagree about it within a single response.
	local wanted = string.lower(name)
	for key, value in headers do
		if string.lower(key) == wanted then
			return value
		end
	end
	return nil
end

local function defaultTransport(url: string, request: TransportRequest): TransportResponse
	local response = net.request(url, {
		method = request.method :: any,
		body = request.body,
		headers = request.headers,
	})
	return { status = response.status, headers = response.headers, body = response.body }
end

function Http.new(token: string, options: HttpOptions?): Http
	local opts: HttpOptions = options or {}
	return setmetatable({
		token = token,
		userAgent = opts.userAgent or Const.USER_AGENT,
		maxRetries = opts.maxRetries or 3,
		transport = opts.transport or defaultTransport,
		baseUrl = opts.baseUrl or Const.API_BASE,
		backoffBase = opts.backoffBase or 0.5,
		backoffCap = opts.backoffCap or 10,
		buckets = {},
		bucketCount = 0,
		sweepAt = SWEEP_MIN,
		routeToBucket = {},
		globalResetAt = nil :: Util.Instant?,
		globalWait = 0,
		windowStart = Util.now(),
		windowCount = 0,
		requestCount = 0,
		rateLimitHits = 0,
	}, Http)
end

--[[
	The bucket a route is currently limited under.

	Discord's bucket hash is shared across major parameters: POST to channel
	A and POST to channel B report the SAME `x-ratelimit-bucket`, yet each
	channel has its own allowance. So a learned bucket is stored under hash
	plus major parameter; keyed by hash alone, a busy channel would make
	every other channel wait out its reset.
]]
local function putBucket(self: Http, storage: string, bucket: Bucket?)
	local had = self.buckets[storage] ~= nil
	self.buckets[storage] = bucket
	if bucket ~= nil and not had then
		self.bucketCount += 1
	elseif bucket == nil and had then
		self.bucketCount -= 1
	end
end

local function getBucket(self: Http, route: string, major: string): Bucket
	local hash = self.routeToBucket[route]
	local storage = (hash or route) .. major
	local bucket = self.buckets[storage]
	if bucket == nil then
		local fresh: Bucket = {
			limit = 1,
			remaining = 1,
			resetAt = nil :: Util.Instant?,
			resetAfter = 0,
			locked = false,
		}
		putBucket(self, storage, fresh)
		bucket = fresh
	end
	return bucket
end

--[[
	Drops buckets that no longer constrain anything: unlocked, and either
	never told of a reset or past it. A fresh bucket behaves the same as
	such a one (the next response re-teaches the limit), so dropping it
	loses nothing -- and without this, per-interaction and per-webhook-token
	keys would grow the table by a few entries for every interaction ever
	handled. A locked bucket, or one still waiting out a reset or a 429, is
	kept: it is the only thing between the next caller and a 429.
]]
local function sweep(self: Http)
	for storage, bucket in self.buckets do
		local resetAt = bucket.resetAt
		if not bucket.locked and (resetAt == nil or Util.since(resetAt) >= bucket.resetAfter) then
			putBucket(self, storage, nil)
		end
	end
	self.sweepAt = math.max(SWEEP_MIN, self.bucketCount * 2)
end

--[[
	Waits out a global 429, then the proactive per-second ceiling.

	Called with the bucket lock already held, immediately before the request
	goes out, so a request that queued on its bucket before a global 429
	landed still sees the pause instead of firing straight into it.
]]
local function waitForGlobal(self: Http)
	local resetAt = self.globalResetAt
	while resetAt ~= nil do
		local remaining = self.globalWait - Util.since(resetAt)
		if remaining <= 0 then
			self.globalResetAt = nil
			break
		end
		task.wait(remaining)
		resetAt = self.globalResetAt
	end

	-- A loop, not a single wait: several requests can be parked here at
	-- once, and if each one reset the window on waking they would all go
	-- out together and the ceiling would stop meaning anything.
	while true do
		if Util.since(self.windowStart) >= 1 then
			self.windowStart = Util.now()
			self.windowCount = 0
		end
		if self.windowCount < GLOBAL_PER_SECOND then
			break
		end
		task.wait(math.max(0.001, 1 - Util.since(self.windowStart)))
	end
	self.windowCount += 1
end

local function acquire(self: Http, route: string, major: string): Bucket
	local bucket = (getBucket(self, route, major))
	-- One in-flight request per bucket. The wait is a poll rather than a
	-- queue because Lute has no condition variable, and 5ms of latency on a
	-- contended bucket is irrelevant next to a network round trip. The
	-- bucket is looked up again each time round because the route may have
	-- been mapped to its real bucket by the request that held the lock.
	while bucket.locked do
		task.wait(0.005)
		bucket = (getBucket(self, route, major))
	end
	bucket.locked = true

	while bucket.remaining <= 0 do
		local resetAt = bucket.resetAt
		if resetAt == nil then
			break
		end
		local remaining = bucket.resetAfter - Util.since(resetAt)
		if remaining <= 0 then
			bucket.remaining = bucket.limit
			break
		end
		-- The route, not the full key: a webhook's major parameter holds
		-- its token, which must not reach a log file.
		Log.debug(`rate limit: waiting {string.format("%.2f", remaining)}s for bucket {route}`)
		task.wait(remaining)
	end
	bucket.remaining -= 1
	return bucket
end

--- Folds a response's rate-limit headers into the bucket the route now
--- maps to, and returns that bucket.
local function applyHeaders(
	self: Http,
	route: string,
	major: string,
	bucket: Bucket,
	headers: { [string]: string }
): Bucket
	local hash = header(headers, "x-ratelimit-bucket")
	if hash ~= nil and self.routeToBucket[route] ~= hash then
		-- Learned which real bucket this route belongs to. Move the state
		-- across and drop the provisional entry, which nothing will consult
		-- again. Anyone parked on it looks the bucket up afresh on waking.
		local provisional = (self.routeToBucket[route] or route) .. major
		self.routeToBucket[route] = hash
		local storage = hash .. major
		if self.buckets[storage] == nil then
			putBucket(self, storage, bucket)
		end
		if self.buckets[provisional] == bucket and provisional ~= storage then
			putBucket(self, provisional, nil)
		end
	end
	local target = (getBucket(self, route, major))
	local limit = tonumber(header(headers, "x-ratelimit-limit"))
	local remaining = tonumber(header(headers, "x-ratelimit-remaining"))
	local resetAfter = tonumber(header(headers, "x-ratelimit-reset-after"))
	if limit ~= nil then
		target.limit = limit
	end
	if remaining ~= nil then
		target.remaining = remaining
	end
	if resetAfter ~= nil then
		target.resetAfter = resetAfter
		target.resetAt = Util.now()
	end
	return target
end

type Part = { name: string, filename: string?, contentType: string?, data: string }

--[[
	A header parameter value. A quote ends the value early, a backslash is
	an escape character to some parsers, and a CR or LF starts a new header
	-- so a file named `a".png` or one with a newline in it would corrupt
	the whole body. Percent-encoding is what browsers do for the same case.
]]
local function quoted(text: string): string
	local stripped = string.gsub(text, "[\r\n]", "")
	local escaped = string.gsub(stripped, '["\\]', function(char: string): string
		return string.format("%%%02X", string.byte(char))
	end)
	return escaped
end

local function bytes(data: string | buffer): string
	return if type(data) == "string" then data else buffer.tostring(data :: buffer)
end

--[[
	Assembles a multipart body by hand.

	Lute's HTTP client takes a string body and nothing else, so uploads are
	built here. The boundary is drawn from the seeded RNG; a fixed one would
	corrupt any upload whose bytes happened to contain it.
]]
local function encodeParts(parts: { Part }): (string, string)
	local boundary = "----lute" .. string.format("%08x%08x", math.random(0, 0xFFFFFFFF), math.random(0, 0xFFFFFFFF))
	local out = {}
	for _, part in parts do
		local disposition = `Content-Disposition: form-data; name="{quoted(part.name)}"`
		local filename = part.filename
		if filename ~= nil then
			disposition ..= `; filename="{quoted(filename)}"`
		end
		local contentType = if part.contentType ~= nil then `\r\nContent-Type: {part.contentType}` else ""
		table.insert(out, `--{boundary}\r\n{disposition}{contentType}\r\n\r\n{part.data}\r\n`)
	end
	table.insert(out, `--{boundary}--\r\n`)
	return table.concat(out), `multipart/form-data; boundary={boundary}`
end

--- An empty table as `{}`: `@std/json` writes it as `[]`, which Discord
--- rejects wherever it expects an object.
local function asObject(value: any): any
	if type(value) == "table" and next(value) == nil then
		return Json.object()
	end
	return value
end

--[[
	The `payload_json` + `files[n]` shape most upload routes take.

	Each new file needs an entry in `attachments` whose `id` is its index
	among the `files[n]` parts. Entries the caller already put there are
	kept: on an edit they are the EXISTING attachments to retain, and
	dropping them deletes those files from the message.

	`attachments` belongs to the message object, which is `body[path]` when
	a path is given (see `RequestOptions.attachmentsPath`).

	On an edit (PATCH), Discord APPENDS new files when `attachments` is
	absent, and treats a present one as the complete list to keep. So an
	edit that only adds files leaves `attachments` out; sending one listing
	just the new uploads would delete every file already on the message.
	The array is sent when the caller gave a keep-list (it is merged) or a
	new file carries a description (only the array can carry it) -- the
	latter drops existing files unless the caller lists them, which is
	logged, because there is no way to append a described file.
]]
local function multipart(payload: any, files: { File }, path: string?, isEdit: boolean): (string, string)
	local attachments = {}
	local supplied: { [string]: any } = {}
	local json = payload or {}
	local message: any = json
	if type(json) == "table" then
		json = Util.copy(json)
		message = json
		if path ~= nil then
			local nested = json[path]
			message = if type(nested) == "table" then Util.copy(nested :: any) else {}
			json[path] = message
		end
	end
	local callerList = type(message) == "table" and type(message.attachments) == "table"
	if type(message) == "table" then
		for _, entry in (if callerList then message.attachments else {}) :: { any } do
			local id = if type(entry) == "table" then tostring(entry.id) else nil
			local index = if id ~= nil then tonumber(id) else nil
			if id ~= nil and index ~= nil and index < #files then
				-- Metadata for one of the new files (a description, say).
				supplied[id] = entry
			else
				table.insert(attachments, entry)
			end
		end
	end
	local described = false
	for index, file in files do
		local id = tostring(index - 1)
		local entry = { id = id, filename = file.name, description = file.description }
		for field, value in supplied[id] or {} do
			if (entry :: any)[field] == nil then
				(entry :: any)[field] = value
			end
		end
		if entry.description ~= nil then
			described = true
		end
		table.insert(attachments, entry)
	end
	if type(message) == "table" then
		if not isEdit or callerList then
			message.attachments = attachments
		elseif described then
			Log.debug(
				"editing with described files and no `attachments` keep-list: "
					.. "the message's existing attachments will be removed"
			)
			message.attachments = attachments
		end
	end

	local parts: { Part } = {
		{ name = "payload_json", contentType = "application/json", data = Json.encode(asObject(json)) },
	}
	for index, file in files do
		table.insert(parts, {
			name = `files[{index - 1}]`,
			filename = file.name,
			contentType = file.contentType or "application/octet-stream",
			data = bytes(file.data),
		})
	end
	return encodeParts(parts)
end

--- The plain form shape; see `RequestOptions.form`. Keys are sorted so the
--- body is deterministic, which keeps it testable and diffable.
local function form(spec: { fields: { [string]: string }?, files: { [string]: File }? }): (string, string)
	local parts: { Part } = {}
	local fields: { [string]: string } = spec.fields or {}
	local names: { string } = {}
	for name in fields do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		table.insert(parts, { name = name, data = fields[name] })
	end
	local files: { [string]: File } = spec.files or {}
	local fileNames: { string } = {}
	for name in files do
		table.insert(fileNames, name)
	end
	table.sort(fileNames)
	for _, name in fileNames do
		local file = files[name]
		table.insert(parts, {
			name = name,
			filename = file.name,
			contentType = file.contentType or "application/octet-stream",
			data = bytes(file.data),
		})
	end
	return encodeParts(parts)
end

--[[
	Performs one REST call, waiting out rate limits and retrying what is
	safe to retry. Returns the decoded body, or `nil` for 204 No Content.
	Throws an `ApiError` on a status Discord will not change its mind about.
]]
function Http.request(self: Http, method: string, path: string, options: RequestOptions?): any
	local opts: RequestOptions = options or {}
	local route = routeOf(method, path)
	local major = majorOf(path)
	-- Discord exempts interaction endpoints from the global limit.
	local exempt = opts.interaction == true or string.sub(path, 1, 14) == "/interactions/"
	local url = self.baseUrl .. path .. Util.query(opts.query)
	local maxRetries = opts.retries or self.maxRetries

	local headers: { [string]: string } = {
		["User-Agent"] = self.userAgent,
		["Accept"] = "application/json",
	}
	if not opts.noAuth then
		headers["Authorization"] = "Bot " .. self.token
	end
	if opts.reason ~= nil then
		-- Shows up in the guild's audit log. Must be percent-encoded: a
		-- newline or non-ASCII byte in a header value is a protocol error.
		headers["X-Audit-Log-Reason"] = Util.encodeComponent(opts.reason)
	end
	for name, value in opts.headers or {} do
		headers[name] = value
	end

	local body: string? = nil
	local spec = opts.form
	if spec ~= nil then
		if opts.body ~= nil or opts.files ~= nil then
			error("`form` cannot be combined with `body` or `files`: it is a different multipart shape", 2)
		end
		local encoded, contentType = form(spec)
		body = encoded
		headers["Content-Type"] = contentType
	elseif opts.files ~= nil and #opts.files > 0 then
		local encoded, contentType = multipart(opts.body, opts.files, opts.attachmentsPath, method == "PATCH")
		body = encoded
		headers["Content-Type"] = contentType
	elseif opts.body ~= nil then
		body = Json.encode(if opts.list then opts.body else asObject(opts.body))
		headers["Content-Type"] = "application/json"
	end

	if self.bucketCount > self.sweepAt then
		sweep(self)
	end

	local attempt = 0
	while true do
		local bucket = acquire(self, route, major)
		if not exempt then
			waitForGlobal(self)
		end
		self.requestCount += 1

		local ok, response = pcall(self.transport, url, {
			method = method,
			body = body,
			headers = headers,
		})

		local target = bucket
		if ok then
			target = applyHeaders(self, route, major, bucket, response.headers)
		end

		if not ok then
			bucket.locked = false
			-- Connection reset, DNS failure, TLS hiccup. Only retry methods
			-- that are safe to repeat: a retried POST can double-post.
			local retryable = method == "GET" or method == "HEAD" or method == "PUT" or method == "DELETE"
			attempt += 1
			if not retryable or attempt > maxRetries then
				error(ApiError.new(0, method, path, { message = `transport failure: {tostring(response)}` }), 0)
			end
			local delay = Util.backoff(attempt, self.backoffBase, self.backoffCap)
			Log.warn(`{method} {path} failed ({tostring(response)}); retry {attempt} in {string.format("%.1f", delay)}s`)
			task.wait(delay)
			continue
		end

		local status = response.status
		local decoded = if response.body ~= "" then (Json.decode(response.body)) else nil

		if status == 429 then
			self.rateLimitHits += 1
			local payload = if type(decoded) == "table" then decoded else {}
			local retryAfter = tonumber(payload.retry_after)
				or tonumber(header(response.headers, "retry-after"))
				or 1
			local scope = header(response.headers, "x-ratelimit-scope")
			if payload.global == true or scope == "global" then
				-- Global: every bucket has to stop, not just this one.
				self.globalResetAt = Util.now()
				self.globalWait = retryAfter
				Log.warn(`globally rate limited for {retryAfter}s`)
			else
				-- Park the pause on the bucket itself, before the lock is
				-- released. Sleeping here instead would leave the bucket
				-- open, and every queued request on it would walk into the
				-- same 429 -- which is how "invalid request" bans happen.
				target.remaining = 0
				target.resetAt = Util.now()
				target.resetAfter = retryAfter
				Log.warn(`rate limited on {route} for {retryAfter}s (scope {scope or "user"})`)
			end
			bucket.locked = false
			attempt += 1
			if attempt > maxRetries then
				error(ApiError.new(429, method, path, payload), 0)
			end
			continue
		end
		bucket.locked = false

		if status >= 500 and status < 600 then
			attempt += 1
			if attempt > maxRetries then
				error(ApiError.new(status, method, path, decoded), 0)
			end
			local delay = Util.backoff(attempt, self.backoffBase, self.backoffCap)
			Log.warn(`{method} {path} -> {status}; retry {attempt} in {string.format("%.1f", delay)}s`)
			task.wait(delay)
			continue
		end

		if status < 200 or status >= 300 then
			error(ApiError.new(status, method, path, decoded), 0)
		end

		Log.debug(`{method} {path} -> {status}`)
		return decoded
	end
end

function Http.get(self: Http, path: string, options: RequestOptions?): any
	return Http.request(self, "GET", path, options)
end

function Http.post(self: Http, path: string, options: RequestOptions?): any
	return Http.request(self, "POST", path, options)
end

function Http.patch(self: Http, path: string, options: RequestOptions?): any
	return Http.request(self, "PATCH", path, options)
end

function Http.put(self: Http, path: string, options: RequestOptions?): any
	return Http.request(self, "PUT", path, options)
end

function Http.delete(self: Http, path: string, options: RequestOptions?): any
	return Http.request(self, "DELETE", path, options)
end

-- Exposed for the test suite; the bucket key rule is the part most worth
-- pinning down, since getting it wrong only shows up under load.
Http._routeKey = routeKey
Http._route = routeOf
Http._header = header

return Http
