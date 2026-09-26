--!strict
--[[
	Storage: the failure that matters is coming back up EMPTY, so most of
	these deliberately corrupt files on disk and check what survives.
]]
local fs = require("@lute/fs")
local task = require("@lute/task")

local Json = require("@discord/json")
local Storage = require("@discord/storage")
local h = require("./harness")

local DIR = "./tests/.tmp-storage"
if not fs.exists(DIR) then
	fs.mkdir(DIR)
end

local counter = 0
local function freshPath(): string
	counter += 1
	local path = `{DIR}/s{counter}.json`
	for _, suffix in { "", ".bak", ".tmp", ".corrupt" } do
		if fs.exists(path .. suffix) then
			fs.remove(path .. suffix)
		end
	end
	return path
end

local function put(path: string, text: string)
	local handle = fs.open(path, "w")
	fs.write(handle, text)
	fs.close(handle)
end

local function read(path: string): string
	local handle = fs.open(path, "r")
	local text = fs.read(handle)
	fs.close(handle)
	return text
end

----------------------------------------------------------------------------
-- Round trip
----------------------------------------------------------------------------
local path = freshPath()
-- debounce 0 keeps every test synchronous; the timer path is covered below.
local store = Storage.open(path, { debounce = 0 })
h.equals("missing file starts empty", #store:keys(), 0)
h.equals("get returns the default", store:get("nope", "fallback"), "fallback")

store:set("motto", "ride on")
store:set("count", 7)
h.check("file exists after set", fs.exists(path))

local reopened = Storage.open(path, { debounce = 0 })
h.equals("string survives a reopen", reopened:get("motto"), "ride on")
h.equals("number survives a reopen", reopened:get("count"), 7)
h.equals("has is true for a set key", reopened:has("motto"), true)
h.equals("has is false for an unset key", reopened:has("ghost"), false)

----------------------------------------------------------------------------
-- Nested tables and `touch`
----------------------------------------------------------------------------
reopened:table("bounties")["kid"] = { amount = 250, reason = "bank" }
-- The store cannot see a mutation through the returned reference.
reopened:touch()

local third = Storage.open(path, { debounce = 0 })
h.equals("nested table persisted", third:get("bounties").kid.amount, 250)
h.equals("table() on a fresh key returns empty", next(third:table("brand-new")), nil)

third:delete("count")
h.equals("delete removes the key", Storage.open(path, { debounce = 0 }):get("count"), nil)

----------------------------------------------------------------------------
-- The remove-before-copy bug this module exists to fix
----------------------------------------------------------------------------
local live = freshPath()
local writer = Storage.open(live, { debounce = 0 })
writer:set("a", 1)
-- After any completed write the real file must exist. The old inline version
-- removed the destination first, so a crash here left nothing at all.
h.check("target file exists after write", fs.exists(live))
writer:set("a", 2)
h.check("target still exists after a second write", fs.exists(live))
h.equals("no .tmp is left behind", fs.exists(live .. ".tmp"), false)

----------------------------------------------------------------------------
-- Corruption recovery
----------------------------------------------------------------------------
local wreck = freshPath()
local original = Storage.open(wreck, { debounce = 0 })
original:set("keep", "this")
original:set("keep2", "that") -- second write creates the .bak
h.check("a backup was written", fs.exists(wreck .. ".bak"))

-- Simulate a crash midway through step 3: a truncated main file.
put(wreck, '{"keep": "th')
local recovered = Storage.open(wreck, { debounce = 0 })
h.equals("recovered the key from .bak", recovered:get("keep"), "this")

-- Both copies broken: start empty, but keep the evidence rather than
-- silently overwriting the only copy.
local doomed = freshPath()
local seed = Storage.open(doomed, { debounce = 0 })
seed:set("x", 1)
seed:set("y", 2)
put(doomed, "{not json at all")
put(doomed .. ".bak", "also not json")
local empty = Storage.open(doomed, { debounce = 0 })
h.equals("unreadable store starts empty", #empty:keys(), 0)
h.check("the corrupt file was preserved", fs.exists(doomed .. ".corrupt"))

----------------------------------------------------------------------------
-- Debounce: many sets, one write
----------------------------------------------------------------------------
local batched = Storage.open(freshPath(), { debounce = 60 })
for index = 1, 20 do
	batched:set(`k{index}`, index)
end
h.equals("20 sets performed 0 writes so far", batched.writes, 0)
h.equals("store is marked dirty", batched.dirty, true)
batched:close()
h.equals("close flushed exactly once", batched.writes, 1)
h.equals("close cleared the dirty flag", batched.dirty, false)
h.throws("a closed store refuses writes", "closed", function()
	batched:set("late", true)
end)
batched:close() -- idempotent
h.equals("closing twice does not write again", batched.writes, 1)

----------------------------------------------------------------------------
-- The stored file is real, readable JSON
----------------------------------------------------------------------------
local readable = freshPath()
local pretty = Storage.open(readable, { debounce = 0 })
pretty:set("nested", { list = { 1, 2, 3 }, flag = true })
local decoded = Json.decode(read(readable))
h.check("file parses as JSON", decoded ~= nil)
h.equals("nested list survives encoding", decoded.nested.list[2], 2)
h.equals("boolean survives encoding", decoded.nested.flag, true)

-- Clean up everything this suite wrote.
-- A change made while a flush is mid-write must not be marked written.
-- `fs.open` yields, so the set below lands inside the spawned flush; before
-- the fix the flush cleared `dirty` on the way out and `close` wrote nothing.
for _, debounce in { 0, 60 } do
	local racePath = freshPath()
	local racer = Storage.open(racePath, { debounce = debounce })
	racer:set("k1", 1)
	task.spawn(Storage.flush, racer)
	racer:set("k2", 2)
	racer:close()
	local reread = Storage.open(racePath, { debounce = 0 })
	h.equals(`a set during an in-flight flush survives close (debounce {debounce})`, reread:get("k2"), 2)
	reread:close()
end

-- A value JSON cannot hold fails the set that stored it, and does not wedge
-- the store: later writes and close still work.
local wedgePath = freshPath()
local wedge = Storage.open(wedgePath, { debounce = 0 })
h.throws("an unencodable value fails its set", "cannot be saved as JSON", function()
	wedge:set("bad", { [5] = "x", [true :: any] = 1 })
end)
wedge:delete("bad")
wedge:set("good", 1)
wedge:close()
h.equals("the store still writes after a failed encode", Storage.open(wedgePath, { debounce = 0 }):get("good"), 1)

for _, entry in fs.listdir(DIR) do
	pcall(fs.remove, `{DIR}/{entry.name}`)
end
pcall(fs.rmdir, DIR)

h.finish()
