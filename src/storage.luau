--!strict
--[[
	A durable JSON key-value store, for the handful of things a bot has to
	remember across restarts: tags, reaction-role mappings, bounties, a
	counter or two.

	=========================================================================
	WHY THIS IS NOT JUST `fs.write`
	=========================================================================

	A bot is killed at arbitrary points -- a deploy, a crash, a machine going
	down mid-write. The failure that matters is not losing the last write; it
	is losing the WHOLE FILE and coming back up empty, silently, having
	forgotten every tag the server ever set.

	Lute has no `fs.rename`, so the usual atomic swap is not available. What
	is available is `fs.copy`, which overwrites its destination in place. So
	the sequence is:

		1. write the new contents to `<path>.tmp`
		2. copy the CURRENT file to `<path>.bak`   (only if it parses)
		3. copy `<path>.tmp` over `<path>`
		4. remove `<path>.tmp`

	The original is never removed before the replacement exists. A crash in
	step 3 can leave `<path>` half-written, and that is what `<path>.bak` is
	for: `open` falls back to it and loses one write instead of all of them.

	This is the fixed version of the pattern the kitchen-sink example used
	inline, which did `fs.remove(path)` before `fs.copy` -- opening a window
	where the file did not exist at all. `fs.copy` overwrites, so the remove
	was never needed and was the one step that could lose everything.

	=========================================================================
	WRITES ARE COALESCED
	=========================================================================

	`set` marks the store dirty and schedules a flush rather than writing
	immediately. A handler that sets twenty keys in a loop performs one
	write, not twenty. `flush` forces it, and `close` flushes synchronously
	-- call it from a shutdown path.

	Set `debounce = 0` for write-through behaviour when a store is small and
	correctness after `kill -9` matters more than syscalls.
]]
local fs = require("@lute/fs")
local task = require("@lute/task")

local blame = require("@discord/blame")
local Json = require("@discord/json")
local Log = require("@discord/log")
local Util = require("@discord/util")

local Storage = {}
Storage.__index = Storage

export type Options = {
	--- Seconds to wait before writing after a change. Default 1.
	--- Zero writes through on every `set`.
	debounce: number?,
	--- Keep a `.bak` alongside the file. Default true.
	backup: boolean?,
}

export type Storage = typeof(setmetatable(
	{} :: {
		path: string,
		data: { [string]: any },
		debounce: number,
		backup: boolean,
		dirty: boolean,
		writes: number,
		_flushQueued: boolean,
		_closed: boolean,
		--- Bumped by every change, so a flush can tell whether the data it
		--- wrote is still the latest.
		_version: number,
		_flushing: boolean,
	},
	{} :: typeof(Storage)
))

local function readFile(path: string): string?
	if not fs.exists(path) then
		return nil
	end
	local ok, contents = pcall(function(): string
		local handle = fs.open(path, "r")
		local text = fs.read(handle)
		fs.close(handle)
		return text
	end)
	if not ok then
		return nil
	end
	return contents
end

local function writeFile(path: string, contents: string)
	local handle = fs.open(path, "w")
	fs.write(handle, contents)
	fs.close(handle)
end

--[[
	Opens `path`, or starts empty if it is missing.

	A file that exists but does not parse is NOT treated as empty on the
	quiet: the `.bak` is tried first, and if that fails too the broken file
	is renamed aside so the next write cannot destroy the evidence.
]]
function Storage.open(path: string, options: Options?): Storage
	local opts: Options = options or {}
	local data: { [string]: any } = {}

	local contents = readFile(path)
	if contents ~= nil then
		local decoded = Json.decode(contents)
		if type(decoded) == "table" then
			data = decoded
		else
			Log.warn(`storage {path} did not parse; trying {path}.bak`)
			local backup = readFile(path .. ".bak")
			local recovered = if backup ~= nil then Json.decode(backup) else nil
			if type(recovered) == "table" then
				data = recovered
				Log.warn(`storage {path} recovered from backup (one write lost)`)
			else
				-- Keep the corrupt file. Starting empty is survivable;
				-- overwriting the only copy of the data is not.
				pcall(fs.copy, path, path .. ".corrupt")
				Log.error(`storage {path} is unreadable and has no usable backup; `
					.. `kept a copy at {path}.corrupt and starting empty`)
			end
		end
	end

	return setmetatable({
		path = path,
		data = data,
		debounce = opts.debounce or 1,
		backup = opts.backup ~= false,
		dirty = false,
		writes = 0,
		_flushQueued = false,
		_closed = false,
		_version = 0,
		_flushing = false,
	}, Storage)
end

function Storage.get(self: Storage, key: string, default: any?): any
	local value = self.data[key]
	if value == nil then
		return default
	end
	return value
end

--- The stored table for `key`, creating it if absent. Mutating the result
--- mutates the store, so call `touch` afterwards.
function Storage.table(self: Storage, key: string): { [string]: any }
	local value = self.data[key]
	if type(value) ~= "table" then
		value = {}
		self.data[key] = value
	end
	return value
end

function Storage.set(self: Storage, key: string, value: any)
	self.data[key] = value
	Storage.touch(self)
end

function Storage.delete(self: Storage, key: string)
	if self.data[key] ~= nil then
		self.data[key] = nil
		Storage.touch(self)
	end
end

function Storage.has(self: Storage, key: string): boolean
	return self.data[key] ~= nil
end

function Storage.keys(self: Storage): { string }
	local out = {}
	for key in self.data do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

--[[
	Marks the store dirty and schedules a flush.

	Call this after mutating a table obtained from `Storage.table` -- the
	store cannot see that happen.
]]
function Storage.touch(self: Storage)
	if self._closed then
		error("storage is closed", 2)
	end
	self.dirty = true
	self._version += 1
	if self.debounce <= 0 then
		Storage.flush(self)
		return
	end
	if self._flushQueued then
		return
	end
	self._flushQueued = true
	-- Sliced, not `task.delay`: `close` flushes synchronously, and a long
	-- debounce timer left behind would hold the process open after it.
	task.spawn(function()
		Util.sleepWhile(self.debounce, function(): boolean
			return not self._closed
		end)
		self._flushQueued = false
		if self.dirty and not self._closed then
			-- Nobody is waiting on this task to hear about a failure, so it
			-- is logged; the store stays dirty and the next change retries.
			local ok, err = pcall(Storage.flush, self)
			if not ok then
				Log.error(tostring(err))
			end
		end
	end)
end

--[[
	Writes now, whether or not anything changed.

	Two things make this more than "encode and write". `fs.open` yields, so
	a `set` can land while a write is in flight: the store only counts as
	clean if nothing changed since the snapshot was taken, otherwise that
	change would be marked written and silently dropped on `close`. And two
	flushes must not interleave, or the older snapshot could land on disk
	after the newer one -- so a flush waits for any write in progress, then
	writes the current data.
]]
function Storage.flush(self: Storage)
	while self._flushing do
		task.wait(0.005)
	end
	self._flushing = true
	local version = self._version
	-- Encoding can throw (a table with non-string keys, a function). Caught
	-- so `_flushing` is always released -- left set, every later flush and
	-- `close` would wait on it forever -- then re-raised. With `debounce =
	-- 0` that fails the `set` that stored the value; with a debounce the
	-- write happens later, on its own task, and the error is logged there.
	-- Either way the store keeps working once the value is removed.
	local encodedOk, encoded = pcall(Json.encode, self.data, true)
	if not encodedOk then
		self._flushing = false
		error(`storage {self.path}: the data cannot be saved as JSON: {tostring(encoded)}`, blame())
	end
	local temporary = self.path .. ".tmp"

	local ok, err = pcall(function()
		writeFile(temporary, encoded)

		-- Back up what is currently on disk BEFORE overwriting it, and only
		-- when it is worth keeping. Backing up an already-corrupt file would
		-- destroy the last good copy.
		if self.backup and fs.exists(self.path) then
			local current = readFile(self.path)
			-- Bound to a local first: `Json.decode` returns (value, error),
			-- and passing the call straight to `type` passes both.
			local parsed = if current ~= nil then (Json.decode(current)) else nil
			if parsed ~= nil and type(parsed) == "table" then
				fs.copy(self.path, self.path .. ".bak")
			end
		end

		-- Overwrites in place. Never `fs.remove` the destination first.
		fs.copy(temporary, self.path)
		fs.remove(temporary)
	end)
	self._flushing = false

	if not ok then
		-- Staying dirty means the next `touch` retries rather than assuming
		-- the write landed.
		Log.error(`storage {self.path} failed to write: {tostring(err)}`)
		return
	end

	self.dirty = self._version ~= version
	self.writes += 1
end

--- Flushes any pending write and refuses further mutation. Idempotent.
function Storage.close(self: Storage)
	if self._closed then
		return
	end
	if self.dirty then
		Storage.flush(self)
	end
	self._closed = true
end

return Storage
