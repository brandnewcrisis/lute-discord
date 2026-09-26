--!strict
--[[
	A 64-bit flag set stored as two 32-bit halves.

	Discord sends permission masks as DECIMAL STRINGS, and for good reason:
	the highest permission bit is 52 today and climbing. Luau has no 64-bit
	integer, `bit32` tops out at 32 bits, and a double stops representing
	consecutive integers exactly above 2^53 -- so `tonumber(perms)` is a bug
	one new permission away from going off. Splitting into `hi`/`lo` sidesteps all of it: the
	halves are always safe integers, and decimal conversion is done with
	long division rather than by touching a float.

	Values are immutable; every operation returns a new field.
]]
local blame = require("@discord/blame")
local Const = require("@discord/const")
local Spec = require("@discord/spec")

local Bitfield = {}
Bitfield.__index = Bitfield

export type Bitfield = typeof(setmetatable(
	{} :: { hi: number, lo: number },
	{} :: typeof(Bitfield)
))

local TWO32 = 4294967296

local function make(hi: number, lo: number): Bitfield
	return setmetatable({ hi = hi % TWO32, lo = lo % TWO32 }, Bitfield)
end

Bitfield.empty = make(0, 0)

--- Builds a field with a single bit set. `bit` must be in [0, 63].
function Bitfield.fromBit(bit: number): Bitfield
	assert(bit >= 0 and bit < 64 and bit % 1 == 0, `bit position out of range: {bit}`)
	if bit < 32 then
		return make(0, 2 ^ bit)
	end
	return make(2 ^ (bit - 32), 0)
end

--- Builds a field from a plain number. Safe for values below 2^53.
function Bitfield.fromNumber(value: number): Bitfield
	assert(value >= 0 and value <= 2 ^ 53, `value out of safe range: {value}`)
	return make(math.floor(value / TWO32), value % TWO32)
end

--[[
	Parses a decimal string, the form Discord actually sends.

	Accumulating with `hi * 10 + carry` stays exact because each intermediate
	is at most 10 * (2^32 - 1), well under 2^53. Overflow past 64 bits wraps,
	which cannot happen with any mask Discord produces.
]]
function Bitfield.fromString(text: string): Bitfield
	local hi, lo = 0, 0
	for index = 1, #text do
		local digit = string.byte(text, index) - 48
		if digit < 0 or digit > 9 then
			-- Names are `coerce`'s job (so `field:has("banMembers")` works);
			-- a caller reaching this directly has a string that is neither.
			error(`not a decimal integer: "{text}"`, blame())
		end
		lo = lo * 10 + digit
		local carry = math.floor(lo / TWO32)
		lo %= TWO32
		hi = (hi * 10 + carry) % TWO32
	end
	return make(hi, lo)
end

-- Permission names as a key set, for suggesting the intended one when a
-- name is misspelt. `Const` and `Spec` require nothing that comes back
-- here, so this module stays a leaf for `Permissions` to build on.
local PERMISSION_NAMES = (function(): Spec.Keys
	local names = {}
	for name in Const.PermissionBits :: { [string]: number } do
		table.insert(names, name)
	end
	return Spec.keys(names)
end)()

--[[
	A permission name as a single-bit field, e.g. `"banMembers"`.

	A typo here must not quietly mean "no bits": `field:has("banMemebrs")`
	returning true for everyone (the empty mask is contained in every field)
	is the classic permission-check hole. So an unknown name throws, naming
	the one that was probably meant.
]]
function Bitfield.fromName(name: string): Bitfield
	local bit = (Const.PermissionBits :: { [string]: number })[name]
	if bit == nil then
		local guess = Spec.suggest(name, PERMISSION_NAMES)
		local hint = if guess ~= nil then `; did you mean "{guess}"?` else ""
		error(`unknown permission "{name}"{hint}`, blame())
	end
	return Bitfield.fromBit(bit)
end

--[[
	Accepts whichever representation turned up: a field, a number, the
	decimal string Discord sends, or a permission name. A string of digits
	is always a mask, never a name -- no permission name is numeric.
]]
function Bitfield.coerce(value: string | number | Bitfield): Bitfield
	if type(value) == "string" then
		if string.find(value, "^%d*$") == nil then
			return Bitfield.fromName(value)
		end
		return Bitfield.fromString(value)
	elseif type(value) == "number" then
		return Bitfield.fromNumber(value)
	end
	return value
end

--- Combines any mix of permission names, decimal-string masks, number masks
--- and fields. Numbers are masks, not bit positions; use `fromBit` for those.
function Bitfield.of(...: string | number | Bitfield): Bitfield
	local hi, lo = 0, 0
	for index = 1, select("#", ...) do
		local part = Bitfield.coerce((select(index, ...)))
		hi = bit32.bor(hi, part.hi)
		lo = bit32.bor(lo, part.lo)
	end
	return make(hi, lo)
end

--- True when every bit of `other` is set here.
function Bitfield.has(self: Bitfield, other: string | number | Bitfield): boolean
	local mask = Bitfield.coerce(other)
	return bit32.band(self.hi, mask.hi) == mask.hi and bit32.band(self.lo, mask.lo) == mask.lo
end

--- True when at least one bit of `other` is set here.
function Bitfield.hasAny(self: Bitfield, other: string | number | Bitfield): boolean
	local mask = Bitfield.coerce(other)
	return bit32.band(self.hi, mask.hi) ~= 0 or bit32.band(self.lo, mask.lo) ~= 0
end

function Bitfield.union(self: Bitfield, other: string | number | Bitfield): Bitfield
	local mask = Bitfield.coerce(other)
	return make(bit32.bor(self.hi, mask.hi), bit32.bor(self.lo, mask.lo))
end

function Bitfield.without(self: Bitfield, other: string | number | Bitfield): Bitfield
	local mask = Bitfield.coerce(other)
	return make(bit32.band(self.hi, bit32.bnot(mask.hi)), bit32.band(self.lo, bit32.bnot(mask.lo)))
end

function Bitfield.intersect(self: Bitfield, other: string | number | Bitfield): Bitfield
	local mask = Bitfield.coerce(other)
	return make(bit32.band(self.hi, mask.hi), bit32.band(self.lo, mask.lo))
end

function Bitfield.isEmpty(self: Bitfield): boolean
	return self.hi == 0 and self.lo == 0
end

--- The set bit positions, ascending.
function Bitfield.bits(self: Bitfield): { number }
	local out = {}
	for index = 0, 31 do
		if bit32.extract(self.lo, index, 1) == 1 then
			table.insert(out, index)
		end
	end
	for index = 0, 31 do
		if bit32.extract(self.hi, index, 1) == 1 then
			table.insert(out, index + 32)
		end
	end
	return out
end

--[[
	Renders as a decimal string for the wire.

	Long division by 10 over the two halves: the remainder is always below 10,
	so `remainder * 2^32 + half` peaks around 4.3e10 and stays exact.
]]
function Bitfield.toString(self: Bitfield): string
	if self.hi == 0 and self.lo == 0 then
		return "0"
	end
	local hi, lo = self.hi, self.lo
	local digits = {}
	while hi ~= 0 or lo ~= 0 do
		local current = hi
		local quotientHi = math.floor(current / 10)
		local remainder = current % 10

		current = remainder * TWO32 + lo
		local quotientLo = math.floor(current / 10)
		remainder = current % 10

		table.insert(digits, 1, string.char(48 + remainder))
		hi, lo = quotientHi, quotientLo
	end
	return table.concat(digits)
end

--- Exact only below 2^53; use `toString` for anything headed for the wire.
function Bitfield.toNumber(self: Bitfield): number
	return self.hi * TWO32 + self.lo
end

Bitfield.__tostring = Bitfield.toString

function Bitfield.__eq(self: Bitfield, other: Bitfield): boolean
	return self.hi == other.hi and self.lo == other.lo
end

return Bitfield
