--!strict
local Snowflake = require("@discord/snowflake")
local h = require("./harness")

-- Discord's own documented example: 175928847299117063 was created at
-- 2016-04-30T11:18:25.796Z.
local EXAMPLE = "175928847299117063"
h.equals("documented timestamp", Snowflake.timestamp(EXAMPLE), 1462015105.796)
h.check("iso date", string.find(Snowflake.isoDate(EXAMPLE), "2016%-04%-30") ~= nil)

-- The low 22 bits are worker/process/increment, not time, so two ids from
-- the same millisecond must agree exactly.
h.check(
	"ids from the same millisecond share a timestamp",
	Snowflake.timestamp("175928847299117063") == Snowflake.timestamp("175928847299117064")
)

-- Precision is the whole point. A 19-digit snowflake does not survive a
-- double, so the naive `tonumber(id) / 2^22` route is off by milliseconds;
-- the string division must land on the exact value.
h.equals("no float rounding in the quotient", Snowflake.timestamp("1541340043497574400"), 1787554503.083)
h.check(
	"ids one millisecond apart differ",
	Snowflake.timestamp("175928851493425152") - Snowflake.timestamp(EXAMPLE) > 0.9
)

local now = 1700000000
local made = Snowflake.fromTimestamp(now)
h.check("synthetic id is a snowflake", Snowflake.isValid(made))
h.equals("synthetic id roundtrips", Snowflake.timestamp(made), now)

h.check("rejects short ids", not Snowflake.isValid("12345"))
h.check("rejects non-numeric", not Snowflake.isValid("1234567890abcdefg"))
-- An id that has been through a number is not a valid id any more, even
-- though it still looks like one; `isValid` insists on the string form.
h.check("rejects non-strings", not Snowflake.isValid(tonumber(EXAMPLE)))
h.check("age of a recent id is small", math.abs(Snowflake.age(Snowflake.fromTimestamp(os.time()))) < 2)

h.finish()
