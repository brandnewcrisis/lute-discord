--!strict
--[[
	The error level of the first stack frame outside this library, for
	`error(message, blame())`.

	The builders exist to fail at the line in the bot that made the mistake,
	not somewhere inside `components.luau`. The usual tool is `error(msg,
	level)` with the level threaded through every helper -- but the Luau
	compiler inlines small local functions, which removes their frames, so a
	counted level lands on the wrong frame (or on none, and the message loses
	its location entirely). Walking the real stack does not care how many
	frames the optimiser kept.

	"Inside the library" means "in the same directory as this file", which
	holds whether the library is run from its own checkout (`./src/`) or
	vendored into someone else's (`./vendor/lute-discord/src/`).
]]
local HERE = debug.info(1, "s")
local LIBRARY = string.match(HERE, "^(.*[/\\])") or HERE

--[[
	Returned rather than raised so the call site is a plain `error(...)`:
	the type checker narrows after `error`, but not after a call to a
	function typed `never`, so `if x == nil then error(msg, blame()) end`
	still leaves `x` non-nil below it.
]]
local function blame(): number
	-- For `debug.info`, level 1 is this function and 2 is the library code
	-- that called it. The result is relative to that caller, whose own
	-- level for `error` is 1 -- hence the final `- 1`.
	local level = 2
	while true do
		local source = debug.info(level, "s")
		if source == nil or string.sub(source, 1, #LIBRARY) ~= LIBRARY then
			break
		end
		level += 1
	end
	return level - 1
end

return blame
