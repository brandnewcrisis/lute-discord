--!strict
--[[
	Cache. The interesting cases are the ones where two structures have to
	stay in step -- `roles[guildId]` alongside `guild.roles`, and channels
	alongside `channelGuild` -- because a permission check walks one and a
	lookup walks the other, so a drift shows up as a wrong answer, not a
	crash.
]]
local Cache = require("@discord/cache")
local h = require("./harness")

local function role(id: string, name: string, position: number): any
	return { id = id, name = name, position = position, permissions = "0" }
end

local function guild(): any
	return {
		id = "g1",
		name = "Dry Gulch",
		owner_id = "u-owner",
		roles = { role("g1", "@everyone", 0), role("r-deputy", "Deputy", 5) },
		channels = { { id = "c-saloon", name = "saloon", type = 0 } },
		members = { { user = { id = "u1", username = "kid" }, roles = { "r-deputy" } } },
	}
end

----------------------------------------------------------------------------
-- GUILD_CREATE fans out into every sub-structure
----------------------------------------------------------------------------
local cache = Cache.new(true)
cache:putGuild(guild())

h.check("guild is cached", cache:getGuild("g1") ~= nil)
h.equals("nil guild id returns nil, not an error", cache:getGuild(nil), nil)
h.check("nested channel was cached", cache:getChannel("c-saloon") ~= nil)
h.check("nested member was cached", cache:getMember("g1", "u1") ~= nil)
h.check("member's user was cached too", cache:getUser("u1") ~= nil)
h.check("nested role was cached", cache:getRole("g1", "r-deputy") ~= nil)
h.equals("unknown role is nil", cache:getRole("g1", "nope"), nil)
h.equals("roles of an unknown guild is an empty table", next(cache:getRoles("nope")), nil)

-- A channel arriving inside a guild must learn its guild id, since gateway
-- events often carry only a channel id.
local channel = cache:getChannel("c-saloon")
h.equals("channel learned its guild id", (channel :: any).guild_id, "g1")

----------------------------------------------------------------------------
-- putRole keeps the map and the guild's own array in step
----------------------------------------------------------------------------
cache:putRole("g1", role("r-marshal", "Marshal", 9))
h.check("new role is in the map", cache:getRole("g1", "r-marshal") ~= nil)

local function findInArray(id: string): any
	for _, entry in (cache:getGuild("g1") :: any).roles do
		if entry.id == id then
			return entry
		end
	end
	return nil
end
h.check("new role is also in guild.roles", findInArray("r-marshal") ~= nil)

-- Updating an existing role must replace it in the array, not append a
-- duplicate -- a duplicate would make permission resolution apply it twice.
cache:putRole("g1", role("r-deputy", "Deputy Renamed", 6))
h.equals("updated role is replaced in the map", (cache:getRole("g1", "r-deputy") :: any).name, "Deputy Renamed")
h.equals("updated role is replaced in the array", (findInArray("r-deputy") :: any).name, "Deputy Renamed")

local total = 0
for _, entry in (cache:getGuild("g1") :: any).roles do
	if entry.id == "r-deputy" then
		total += 1
	end
end
h.equals("updating did not duplicate the role", total, 1)

cache:removeRole("g1", "r-deputy")
h.equals("removed role is gone from the map", cache:getRole("g1", "r-deputy"), nil)
h.equals("removed role is gone from the array", findInArray("r-deputy"), nil)

----------------------------------------------------------------------------
-- Removing a guild must not orphan its channels
----------------------------------------------------------------------------
local orphans = Cache.new(true)
orphans:putGuild(guild())
orphans:putChannel({ id = "c-other", name = "elsewhere", type = 0 } :: any, "g2")
orphans:removeGuild("g1")

h.equals("guild is gone", orphans:getGuild("g1"), nil)
h.equals("its channel is gone", orphans:getChannel("c-saloon"), nil)
h.equals("its roles are gone", next(orphans:getRoles("g1")), nil)
h.equals("its members are gone", orphans:getMember("g1", "u1"), nil)
h.check("another guild's channel survived", orphans:getChannel("c-other") ~= nil)

orphans:removeChannel("c-other")
h.equals("removed channel is gone", orphans:getChannel("c-other"), nil)

----------------------------------------------------------------------------
-- A member with no user object is not cacheable
----------------------------------------------------------------------------
local partial = Cache.new(true)
partial:putGuild(guild())
partial:putMember("g1", { roles = {} } :: any)
h.equals("a member without a user is skipped", partial:stats().members, 1)
partial:putUser(nil)
h.equals("putUser(nil) is a no-op", partial:stats().users, 1)

----------------------------------------------------------------------------
-- Disabled cache stores nothing but still answers
----------------------------------------------------------------------------
local off = Cache.new(false)
off:putGuild(guild())
off:putRole("g1", role("r-x", "X", 1))
off:putChannel({ id = "c-x", type = 0 } :: any, "g1")
h.equals("disabled cache stores no guild", off:getGuild("g1"), nil)
h.equals("disabled cache stores no role", off:getRole("g1", "r-x"), nil)
h.equals("disabled cache stores no channel", off:getChannel("c-x"), nil)
h.equals("disabled cache still reports stats", off:stats().guilds, 0)

----------------------------------------------------------------------------
-- Stats count across guilds, not within one
----------------------------------------------------------------------------
local counted = Cache.new(true)
counted:putGuild(guild())
local second = guild()
second.id = "g2"
second.channels = { { id = "c-b", type = 0 } }
second.members = { { user = { id = "u2", username = "pete" }, roles = {} } }
counted:putGuild(second)

local stats = counted:stats()
h.equals("counts both guilds", stats.guilds, 2)
h.equals("counts channels across guilds", stats.channels, 2)
h.equals("counts members across guilds", stats.members, 2)
h.equals("counts roles across guilds", stats.roles, 4)
h.equals("counts distinct users", stats.users, 2)

-- Cleared fields: Discord sends `null`, decoding drops the key, and the
-- update must still clear the cached value.
local nulls = Cache.new(true)
nulls:putGuild({ id = "g9", name = "G", icon = "abc", member_count = 12, channels = {}, roles = {} } :: any)
nulls:patchGuild({ id = "g9", name = "G2", roles = {} } :: any)
local g9 = h.some(nulls:getGuild("g9"))
h.equals("GUILD_UPDATE clears a removed icon", g9.icon, nil)
h.equals("GUILD_UPDATE keeps the create-only member_count", g9.member_count, 12)
h.equals("GUILD_UPDATE applies the new name", g9.name, "G2")

nulls:putMember("g9", {
	user = { id = "u9", username = "u" },
	roles = {},
	nick = "Old",
	deaf = true,
	joined_at = "2020-01-01T00:00:00Z",
	communication_disabled_until = "2030-01-01T00:00:00Z",
} :: any)
nulls:patchMember("g9", { user = { id = "u9", username = "u" }, roles = {} } :: any)
local m9 = h.some(nulls:getMember("g9", "u9"))
h.equals("GUILD_MEMBER_UPDATE clears a nickname set to null", m9.nick, nil)
h.equals("GUILD_MEMBER_UPDATE clears a lifted timeout", m9.communication_disabled_until, nil)
h.equals("GUILD_MEMBER_UPDATE keeps deaf, which it never carries", m9.deaf, true)
h.equals("GUILD_MEMBER_UPDATE keeps joined_at when omitted", m9.joined_at, "2020-01-01T00:00:00Z")

-- A channel deleted during an outage never gets a CHANNEL_DELETE; the next
-- GUILD_CREATE is the full list and must drop it.
local outage = Cache.new(true)
outage:putGuild({ id = "g8", roles = {}, channels = { { id = "old", type = 0 }, { id = "kept", type = 0 } } } :: any)
outage:putGuild({ id = "g8", roles = {}, channels = { { id = "kept", type = 0 } } } :: any)
h.equals("a channel missing from a fresh GUILD_CREATE is dropped", outage:getChannel("old"), nil)
h.check("a channel still present survives", outage:getChannel("kept") ~= nil)

h.finish()
