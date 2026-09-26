--!strict
local Bitfield = require("@discord/bitfield")
local Const = require("@discord/const")
local h = require("./harness")

h.equals("empty renders 0", Bitfield.empty:toString(), "0")
h.equals("bit 0", Bitfield.fromBit(0):toString(), "1")
h.equals("bit 31", Bitfield.fromBit(31):toString(), "2147483648")
h.equals("bit 32 crosses the half boundary", Bitfield.fromBit(32):toString(), "4294967296")
h.equals("bit 50 (useExternalApps)", Bitfield.fromBit(50):toString(), "1125899906842624")
h.equals("bit 63", Bitfield.fromBit(63):toString(), "9223372036854775808")

-- The whole reason for the two-half representation: this value is above
-- 2^53, so any implementation that went through a Luau number is wrong here.
local huge = "9223372036854775807"
h.equals("64-bit string roundtrips", Bitfield.fromString(huge):toString(), huge)
h.equals("mixed halves roundtrip", Bitfield.fromString("8589934593"):toString(), "8589934593")

local admin = Bitfield.fromBit(Const.PermissionBits.administrator)
local kick = Bitfield.fromBit(Const.PermissionBits.kickMembers)
local both = admin:union(kick)
h.check("union has both", both:has(admin) and both:has(kick))
h.check("single does not have both", not admin:has(both))
h.check("hasAny is true for one", admin:hasAny(both))
h.check("without removes", not both:without(kick):has(kick))
h.check("without keeps the rest", both:without(kick):has(admin))
h.check("intersect", both:intersect(kick):toString() == kick:toString())
h.check("isEmpty", Bitfield.empty:isEmpty() and not admin:isEmpty())

local bits = Bitfield.fromBit(3):union(Bitfield.fromBit(40)):bits()
h.equals("bits length", #bits, 2)
h.equals("bits are ascending, low half first", bits[1], 3)
h.equals("bits include the high half", bits[2], 40)

h.equals("fromNumber", Bitfield.fromNumber(1024):toString(), "1024")
h.equals("coerce string", Bitfield.coerce("7"):toString(), "7")
h.equals("of combines", Bitfield.of(1, "2", Bitfield.fromBit(2)):toString(), "7")
h.throws("rejects non-decimal", "not a decimal", function()
	Bitfield.fromString("12x")
end)
h.throws("rejects out-of-range bit", "out of range", function()
	Bitfield.fromBit(64)
end)

h.finish()
