--!strict
local Bitfield = require("@discord/bitfield")
local Const = require("@discord/const")
local Permissions = require("@discord/permissions")
local h = require("./harness")

local GUILD_ID = "100"
local function role(id: string, position: number, perms: string): any
	return { id = id, name = `role-{id}`, color = 0, hoist = false, position = position, permissions = perms, managed = false, mentionable = false }
end

local VIEW = Bitfield.fromBit(Const.PermissionBits.viewChannel)
local SEND = Bitfield.fromBit(Const.PermissionBits.sendMessages)
local MANAGE = Bitfield.fromBit(Const.PermissionBits.manageMessages)
local ADMIN = Bitfield.fromBit(Const.PermissionBits.administrator)

local guild: any = {
	id = GUILD_ID,
	name = "test",
	owner_id = "1",
	roles = {
		role(GUILD_ID, 0, VIEW:union(SEND):toString()),
		role("200", 1, MANAGE:toString()),
		role("300", 5, ADMIN:toString()),
	},
}

local function member(userId: string, roles: { string }, timeoutUntil: string?): any
	return { user = { id = userId, username = "u" .. userId }, roles = roles, joined_at = "", communication_disabled_until = timeoutUntil }
end

-- Guild level
local plain = member("2", {})
h.check("everyone role applies", Permissions.forMember(guild, plain):has(SEND))
h.check("unheld role does not", not Permissions.forMember(guild, plain):has(MANAGE))
h.check("held role adds", Permissions.forMember(guild, member("3", { "200" })):has(MANAGE))
h.check("owner gets everything", Permissions.forMember(guild, member("1", {})):has(ADMIN))
h.check("administrator implies everything", Permissions.forMember(guild, member("4", { "300" })):has(MANAGE))

-- Channel overwrites, in Discord's resolution order.
local function channel(overwrites: { any }): any
	return { id = "900", type = 0, guild_id = GUILD_ID, permission_overwrites = overwrites }
end

local denyEveryone = channel({
	{ id = GUILD_ID, type = Const.OverwriteType.ROLE, allow = "0", deny = SEND:toString() },
})
h.check("everyone deny removes it", not Permissions.forChannel(guild, plain, denyEveryone):has(SEND))

-- A role allow must beat the @everyone deny -- this is the ordering rule.
local roleWins = channel({
	{ id = GUILD_ID, type = Const.OverwriteType.ROLE, allow = "0", deny = SEND:toString() },
	{ id = "200", type = Const.OverwriteType.ROLE, allow = SEND:toString(), deny = "0" },
})
h.check("role allow beats everyone deny", Permissions.forChannel(guild, member("5", { "200" }), roleWins):has(SEND))

-- One role's allow must beat another role's deny regardless of order.
local mixed = channel({
	{ id = "200", type = Const.OverwriteType.ROLE, deny = SEND:toString(), allow = "0" },
	{ id = "300", type = Const.OverwriteType.ROLE, allow = SEND:toString(), deny = "0" },
})
local twoRoles = member("6", { "200", "300" })
-- (role 300 carries admin, so check with a non-admin pair instead)
local guildNoAdmin: any = {
	id = GUILD_ID,
	name = "test",
	owner_id = "1",
	roles = { role(GUILD_ID, 0, VIEW:union(SEND):toString()), role("200", 1, "0"), role("300", 2, "0") },
}
h.check(
	"allow on one role beats deny on another",
	Permissions.forChannel(guildNoAdmin, twoRoles, mixed):has(SEND)
)

-- Member overwrite is applied last and wins outright.
local memberDeny = channel({
	{ id = "200", type = Const.OverwriteType.ROLE, allow = SEND:toString(), deny = "0" },
	{ id = "7", type = Const.OverwriteType.MEMBER, allow = "0", deny = SEND:toString() },
})
h.check(
	"member overwrite beats role overwrite",
	not Permissions.forChannel(guildNoAdmin, member("7", { "200" }), memberDeny):has(SEND)
)

-- No view means nothing.
local noView = channel({
	{ id = GUILD_ID, type = Const.OverwriteType.ROLE, allow = "0", deny = VIEW:toString() },
})
h.check("losing view removes everything", Permissions.forChannel(guild, plain, noView):isEmpty())

-- Administrator ignores overwrites entirely.
h.check(
	"administrator ignores channel denies",
	Permissions.forChannel(guild, member("8", { "300" }), noView):has(SEND)
)

-- Timeout strips all but reading.
local future = os.date("!%Y-%m-%dT%H:%M:%S.000000+00:00", os.time() + 3600) :: string
local past = os.date("!%Y-%m-%dT%H:%M:%S.000000+00:00", os.time() - 3600) :: string
local muted = member("9", {}, future)
h.check("timeout detected", Permissions.isTimedOut(muted))
h.check("expired timeout ignored", not Permissions.isTimedOut(member("10", {}, past)))
local mutedPerms = Permissions.forChannel(guild, muted, channel({}))
h.check("timed out member keeps view", mutedPerms:has(VIEW))
h.check("timed out member cannot send", not mutedPerms:has(SEND))

-- Hierarchy
h.check("higher role outranks lower", Permissions.outranks(guildNoAdmin, member("11", { "300" }), member("12", { "200" })))
h.check("equal roles do not outrank", not Permissions.outranks(guildNoAdmin, member("13", { "200" }), member("14", { "200" })))
h.check("owner outranks everyone", Permissions.outranks(guildNoAdmin, member("1", {}), member("15", { "300" })))
h.check("nobody outranks the owner", not Permissions.outranks(guildNoAdmin, member("16", { "300" }), member("1", {})))

-- Names
h.check("of() builds from names", Permissions.of("kickMembers", "banMembers"):has(Permissions.Flags.banMembers))
h.throws("unknown name throws", "unknown permission", function()
	Permissions.of("banMemberz")
end)
h.check("has() treats admin as everything", Permissions.has(ADMIN, "manageGuild"))
h.check("list() names the bits", table.concat(Permissions.list(SEND:union(VIEW)), ",") == "sendMessages,viewChannel")

h.finish()
