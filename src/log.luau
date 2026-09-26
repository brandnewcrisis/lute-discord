--!strict
--[[
	Levelled logging to stdout, and optionally to a file.

	The file sink is not a nicety. Lute block-buffers stdout whenever it is
	not attached to a terminal, which is every way a bot actually runs -- under
	nohup, in a container, from a service manager. A bot that died an hour ago
	shows an empty log without this, which is exactly when you need one.
]]
local fs = require("@lute/fs")

local Log = {}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }
local threshold = LEVELS.info
local filePath: string? = nil
local prefix = ""
local hook: ((level: string, message: string) -> ())? = nil

function Log.setLevel(level: string)
	threshold = LEVELS[level] or LEVELS.info
end

function Log.setFile(path: string?)
	filePath = path
end

--- A tag printed before every line -- shard id, bot name, whatever helps.
function Log.setPrefix(text: string?)
	prefix = if text and text ~= "" then `[{text}] ` else ""
end

--[[
	Calls `fn(level, message)` for every line that passes the level, after
	it is printed. For forwarding warnings to a log channel, or for a test
	asserting that a warning was given. `nil` removes it. A hook that throws
	is ignored: logging must not be what takes a bot down.
]]
function Log.setHook(fn: ((level: string, message: string) -> ())?)
	hook = fn
end

function Log.enabled(level: string): boolean
	return (LEVELS[level] or 0) >= threshold
end

local function emit(level: string, message: string)
	if (LEVELS[level] or 0) < threshold then
		return
	end
	-- UTC, and dated: a bot's log outlives the day it started, and a bare
	-- time cannot say which night the crash was.
	local line = `{os.date("!%Y-%m-%d %H:%M:%S")} {string.upper(level)}\t{prefix}{message}`
	print(line)
	local target = filePath
	if target ~= nil then
		-- Logging must never be the thing that takes a bot down.
		pcall(function()
			-- Lute's "a" mode refuses to create a missing file, so the first
			-- write has to open "w". "rw" is not a substitute: it writes from
			-- offset zero and silently overwrites what is already there.
			local handle = fs.open(target, if fs.exists(target) then "a" else "w")
			fs.write(handle, line .. "\n")
			fs.close(handle)
		end)
	end
	local listener = hook
	if listener ~= nil then
		pcall(listener, level, message)
	end
end

function Log.debug(message: string)
	emit("debug", message)
end

function Log.info(message: string)
	emit("info", message)
end

function Log.warn(message: string)
	emit("warn", message)
end

function Log.error(message: string)
	emit("error", message)
end

return Log
