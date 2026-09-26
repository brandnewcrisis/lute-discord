--!strict
--[[
	Small helpers with no Discord knowledge in them.
]]
local time = require("@std/time")
local task = require("@lute/task")
local crypto = require("@lute/crypto")

local Color = require("@discord/color")

local Util = {}

--[[
	Seed the RNG from the OS CSPRNG, once, at load.

	Lute leaves `math.random` unseeded, so every process draws the identical
	sequence -- which turns jittered reconnect backoff into no jitter at all
	the moment more than one shard restarts together. `secretbox.keygen()` is
	the only source of real entropy the runtime exposes (there is no
	random-bytes call), and seeding off the clock is no good either: shards
	started by the same supervisor share it to the second.
]]
do
	local seedBytes = crypto.secretbox.keygen()
	local seed = 0
	for offset = 0, 5 do
		seed = (seed * 256 + buffer.readu8(seedBytes, offset)) % 2 ^ 48
	end
	math.randomseed(seed)
end

--- Monotonic seconds since `mark`. `os.time()` is wall-clock and jumps when
--- the machine syncs its clock, which is how a heartbeat loop ends up either
--- spinning or hanging; `time.now()` never moves backwards.
export type Instant = time.Instant

function Util.now(): Instant
	return time.now()
end

function Util.since(mark: Instant): number
	return time.since(mark)
end

function Util.sleep(seconds: number)
	task.wait(seconds)
end

--[[
	Sleeps up to `seconds`, waking early -- and returning false -- as soon as
	`keepGoing()` does. Returns true if the full time elapsed.

	This exists because a Lute timer cannot be cancelled. A pending
	`task.delay(3600, ...)` keeps the process alive for the hour even after
	everything else has shut down, so anything that waits a long time on
	behalf of something stoppable (a collector's timeout, a reminder) has to
	wait in slices and check whether it is still wanted. `slice` trades
	shutdown latency for wakeups; a quarter second is invisible either way.
]]
function Util.sleepWhile(seconds: number, keepGoing: () -> boolean, slice: number?): boolean
	local step = slice or 0.25
	local started = time.now()
	while keepGoing() do
		local left = seconds - time.since(started)
		if left <= 0 then
			return true
		end
		task.wait(math.min(step, left))
	end
	return false
end

--- Unix seconds. For anything Discord-facing (timestamps in embeds, audit
--- reasons) this is the right clock; for durations it is not.
function Util.unix(): number
	return os.time()
end

--- Full jitter backoff: `random(0, min(cap, base * 2^attempt))`. Full jitter
--- rather than a fixed multiplier because every shard of a restarted bot
--- reconnects at the same instant otherwise, and Discord counts that as an
--- identify burst.
function Util.backoff(attempt: number, base: number?, cap: number?): number
	local ceiling = math.min(cap or 60, (base or 1) * 2 ^ math.min(attempt, 10))
	return math.random() * ceiling
end

--- URL-encodes a path segment. Channel names and emoji end up in paths, and
--- an unencoded `#` silently truncates the request at the fragment.
function Util.encodeComponent(text: string): string
	return (string.gsub(text, "[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- Builds `?a=1&b=2` from a table, skipping nils. Returns "" when empty.
--- An array value becomes the key repeated once per element
--- (`?id=1&id=2`), which is how Discord reads array query parameters.
function Util.query(params: any?): string
	if params == nil then
		return ""
	end
	local parts = {}
	for key, value in params :: { [string]: any } do
		if type(value) == "table" then
			for _, item in value :: { any } do
				table.insert(parts, `{Util.encodeComponent(key)}={Util.encodeComponent(tostring(item))}`)
			end
		elseif value ~= nil then
			table.insert(parts, `{Util.encodeComponent(key)}={Util.encodeComponent(tostring(value))}`)
		end
	end
	if #parts == 0 then
		return ""
	end
	table.sort(parts)
	return "?" .. table.concat(parts, "&")
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Standard padded base64. Needed for the `image` fields in the API (bot
--- avatar, emoji, guild icon), which take a `data:` URI rather than a file.
function Util.base64(input: string | buffer): string
	local data = if type(input) == "string" then input else buffer.tostring(input)
	local out = {}
	local length = #data
	local index = 1
	while index + 2 <= length do
		local a, b, c = string.byte(data, index, index + 2)
		local packed = a * 65536 + b * 256 + c
		table.insert(
			out,
			string.sub(B64, math.floor(packed / 262144) + 1, math.floor(packed / 262144) + 1)
				.. string.sub(B64, math.floor(packed / 4096) % 64 + 1, math.floor(packed / 4096) % 64 + 1)
				.. string.sub(B64, math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1)
				.. string.sub(B64, packed % 64 + 1, packed % 64 + 1)
		)
		index += 3
	end
	local remaining = length - index + 1
	if remaining == 1 then
		local a = string.byte(data, index)
		local packed = a * 16
		table.insert(
			out,
			string.sub(B64, math.floor(packed / 64) + 1, math.floor(packed / 64) + 1)
				.. string.sub(B64, packed % 64 + 1, packed % 64 + 1)
				.. "=="
		)
	elseif remaining == 2 then
		local a, b = string.byte(data, index, index + 1)
		local packed = (a * 256 + b) * 4
		table.insert(
			out,
			string.sub(B64, math.floor(packed / 4096) + 1, math.floor(packed / 4096) + 1)
				.. string.sub(B64, math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1)
				.. string.sub(B64, packed % 64 + 1, packed % 64 + 1)
				.. "="
		)
	end
	return table.concat(out)
end

--- A `data:` URI for an image payload, the form Discord's `image` fields take.
function Util.dataUri(mime: string, bytes: string | buffer): string
	return `data:{mime};base64,{Util.base64(bytes)}`
end

--- Truncates to `limit` characters, ellipsis included in the budget. Discord
--- rejects an over-long field outright rather than trimming it.
function Util.truncate(text: string, limit: number): string
	if utf8.len(text) == nil then
		-- Not valid UTF-8; fall back to bytes rather than erroring.
		return if #text <= limit then text else string.sub(text, 1, limit - 1) .. "\u{2026}"
	end
	local length = utf8.len(text) :: number
	if length <= limit then
		return text
	end
	local cut = utf8.offset(text, limit) :: number
	return string.sub(text, 1, cut - 1) .. "\u{2026}"
end

local MARKDOWN = { "\\", "*", "_", "~", "`", "|", ">" }

--- Escapes Discord markdown so user-supplied text cannot inject formatting
--- (or, with `>`, a block quote that swallows the rest of the message).
function Util.escapeMarkdown(text: string): string
	local out = text
	for _, char in MARKDOWN do
		out = string.gsub(out, "%" .. char, "\\" .. char)
	end
	return out
end

local UNITS = {
	{ 86400, "d" },
	{ 3600, "h" },
	{ 60, "m" },
	{ 1, "s" },
}

--- "2d 4h 13m" -- the two largest non-zero units, which is what reads well
--- in an uptime field.
function Util.duration(seconds: number): string
	local remaining = math.floor(seconds)
	local parts = {}
	for _, unit in UNITS do
		local size = unit[1] :: number
		local label = unit[2] :: string
		local count = math.floor(remaining / size)
		if count > 0 or (#parts == 0 and size == 1) then
			table.insert(parts, `{count}{label}`)
			remaining -= count * size
		end
		if #parts == 2 then
			break
		end
	end
	return table.concat(parts, " ")
end

--- Discord's inline timestamp markup, rendered in each viewer's own timezone.
--- Style: t/T time, d/D date, f/F full, R relative.
function Util.timestamp(unixSeconds: number, style: string?): string
	return `<t:{math.floor(unixSeconds)}:{style or "f"}>`
end

--- Shallow copy. Payload builders hand out tables that callers then mutate.
function Util.copy<K, V>(source: { [K]: V }): { [K]: V }
	local out = {}
	for key, value in source do
		out[key] = value
	end
	return out
end

--- An RGB integer from a number, a `Const.Color` entry, `#rrggbb` or `#rgb`;
--- nil when the input is not a colour. What `Embed.setColor` and
--- `Components.container` accept, exposed for your own validation.
Util.color = Color.resolve

return Util
