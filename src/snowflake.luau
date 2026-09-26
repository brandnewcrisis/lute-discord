--!strict
--[[
	Snowflake IDs.

	IDs are 64-bit and arrive as strings, and they must stay strings: parsing
	one into a Luau number rounds it, and a rounded ID is a wrong ID that
	still looks plausible. Only the timestamp is extracted here, and it is
	pulled with string arithmetic so the low bits never reach a float.
]]
local Const = require("@discord/const")

local Snowflake = {}

--[[
	Milliseconds since the Discord epoch, i.e. `id >> 22`.

	Shifting right by 22 is dividing by 2^22, and the quotient of a 64-bit
	snowflake is only ~41 bits -- comfortably exact in a double. The problem
	is getting there: `tonumber(id) / 2^22` has already lost the low bits by
	the time it divides. So the division is done on the decimal string, digit
	by digit, and only the (small, exact) quotient becomes a number.
]]
local function shiftRight22(id: string): number
	local quotient = 0
	local remainder = 0
	for index = 1, #id do
		local digit = string.byte(id, index) - 48
		if digit < 0 or digit > 9 then
			error(`not a snowflake: {id}`, 3)
		end
		-- Long division, carrying a remainder that stays below 2^22.
		local current = remainder * 10 + digit
		local part = math.floor(current / 4194304)
		remainder = current % 4194304
		quotient = quotient * 10 + part
	end
	return quotient
end

--- Unix seconds at which the object with this ID was created.
function Snowflake.timestamp(id: string): number
	return (shiftRight22(id) + Const.DISCORD_EPOCH) / 1000
end

--- ISO-8601 UTC creation time, for embed footers and audit output.
function Snowflake.isoDate(id: string): string
	return os.date("!%Y-%m-%d %H:%M:%S UTC", math.floor(Snowflake.timestamp(id))) :: string
end

--- Age in seconds. Used to reject bulk-deleting messages older than 14 days
--- before Discord does, so the error names the real reason.
function Snowflake.age(id: string): number
	return os.time() - Snowflake.timestamp(id)
end

--- A synthetic snowflake for the given time, valid as a `before`/`after`
--- pagination cursor. The low 22 bits are zero, which Discord accepts.
function Snowflake.fromTimestamp(unixSeconds: number): string
	local millis = math.floor(unixSeconds * 1000) - Const.DISCORD_EPOCH
	assert(millis >= 0, "timestamp predates the Discord epoch")
	-- Multiplying back up needs the same care in reverse: build the decimal
	-- digits of `millis * 2^22` with long multiplication.
	local digits = {}
	local carry = 0
	local text = tostring(millis)
	for index = #text, 1, -1 do
		local product = (string.byte(text, index) - 48) * 4194304 + carry
		table.insert(digits, 1, product % 10)
		carry = math.floor(product / 10)
	end
	while carry > 0 do
		table.insert(digits, 1, carry % 10)
		carry = math.floor(carry / 10)
	end
	local out = {}
	for _, digit in digits do
		table.insert(out, string.char(48 + digit))
	end
	return table.concat(out)
end

function Snowflake.isValid(id: any): boolean
	return type(id) == "string" and #id >= 15 and #id <= 21 and string.match(id, "^%d+$") ~= nil
end

return Snowflake
