--!strict
--[[
	Permission flags, and computing what someone may actually do.

	Discord does not tell you a member's effective permissions in a channel;
	it gives you role bitmasks and a list of overwrites, and the resolution
	order is load-bearing:

	    1. the @everyone role's guild permissions, plus every held role's
	    2. ADMINISTRATOR, or being the owner, short-circuits to "everything"
	    3. the @everyone channel overwrite: deny first, then allow
	    4. all role overwrites' denies, then all role overwrites' allows
	    5. the member's own overwrite: deny, then allow
	    6. lacking VIEW_CHANNEL removes every channel permission
	    7. being timed out strips everything but viewing and reading history

	Applying role denies and allows in two passes -- rather than per role --
	is the part that is easy to get wrong: one role's allow is meant to beat
	another role's deny regardless of hierarchy, and a per-role loop makes the
	result depend on role order.
]]
local Bitfield = require("@discord/bitfield")
local Const = require("@discord/const")
local Log = require("@discord/log")
local Types = require("@discord/types")

type Bits = Bitfield.Bitfield

local Permissions = {}

--- Every permission by name, as a single-bit field.
local Flags: { [string]: Bits } = {}
for name, bit in Const.PermissionBits :: { [string]: number } do
	Flags[name] = Bitfield.fromBit(bit)
end
Permissions.Flags = table.freeze(Flags)

Permissions.NONE = Bitfield.empty
Permissions.ALL = (function()
	local all = Bitfield.empty
	for _, flag in Flags do
		all = all:union(flag)
	end
	return all
end)()

--- Combines permission names into one field: `Permissions.of("kickMembers",
--- "banMembers")`. Unknown names throw rather than being ignored, because a
--- typo'd permission name that silently means "no permission" produces a bot
--- that lets everyone through. The error names the likely intended one.
function Permissions.of(...: string): Bits
	local field = Bitfield.empty
	for index = 1, select("#", ...) do
		field = field:union(Bitfield.fromName((select(index, ...))))
	end
	return field
end

--- Parses the decimal string Discord sends.
function Permissions.parse(text: string?): Bits
	if text == nil or text == "" then
		return Bitfield.empty
	end
	return Bitfield.fromString(text)
end

--- The names set in a field, sorted -- for `/permissions` style output.
function Permissions.list(field: Bits): { string }
	local out = {}
	for name, flag in Flags do
		if field:has(flag) then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

--- True if the field grants `permission`, or holds ADMINISTRATOR.
function Permissions.has(field: Bits, permission: string | Bits): boolean
	if field:has(Flags.administrator) then
		return true
	end
	local wanted = if type(permission) == "string" then Permissions.of(permission) else permission
	return field:has(wanted)
end

local warnedAnonymous = false

--[[
	Whose member object this is.

	A member only names its user through `member.user`, and the members an
	interaction resolves (`data.resolved.members`, a select's picks) arrive
	WITHOUT it -- the user sits in a sibling map. Such a member cannot be
	recognised as the guild owner or matched to its own channel overwrite,
	so the owner would be judged by roles alone. An explicit `userId` fills
	the gap; without one, a single warning says why a check may come out
	short, rather than every call guessing silently.
]]
local function memberId(member: Types.Member, userId: string?, what: string): string?
	if userId ~= nil then
		return userId
	end
	local user = member.user
	if user ~= nil then
		return user.id
	end
	if not warnedAnonymous then
		warnedAnonymous = true
		Log.warn(
			`Permissions.{what} got a member with no \`user\` and no userId; the guild owner and member `
				.. "overwrites cannot be recognised. Pass the user id, or use ix:getMember / ix:selectedMembers, "
				.. "which splice the user back in."
		)
	end
	return nil
end

--[[
	Guild-wide permissions for a member: @everyone plus every role held.
	Owners get everything, as does anyone with ADMINISTRATOR.

	`userId` is for members that lack `user` (see `memberId`); when given it
	wins over `member.user`.
]]
function Permissions.forMember(
	guild: Types.Guild,
	member: Types.Member,
	roles: { [string]: Types.Role }?,
	userId: string?
): Bits
	local id = memberId(member, userId, "forMember")
	if id ~= nil and guild.owner_id == id then
		return Permissions.ALL
	end

	local lookup = roles
	if lookup == nil then
		lookup = {}
		for _, role in guild.roles or {} do
			lookup[role.id] = role
		end
	end
	assert(lookup ~= nil)

	-- The @everyone role always shares the guild's id.
	local base = Bitfield.empty
	local everyone = lookup[guild.id]
	if everyone ~= nil then
		base = Bitfield.fromString(everyone.permissions)
	end
	for _, roleId in member.roles do
		local role = lookup[roleId]
		if role ~= nil then
			base = base:union(Bitfield.fromString(role.permissions))
		end
	end

	if base:has(Flags.administrator) then
		return Permissions.ALL
	end
	return base
end

--- ISO-8601 to unix seconds. Discord sends fractional seconds and an offset;
--- only the calendar part is needed to decide whether a timeout has expired.
local function parseIso(text: string?): number?
	if text == nil then
		return nil
	end
	local year, month, day, hour, minute, second =
		string.match(text, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if year == nil then
		return nil
	end
	-- `os.time` reads local time, so the UTC offset has to be added back.
	local localEpoch = os.time({
		year = tonumber(year) :: number,
		month = tonumber(month) :: number,
		day = tonumber(day) :: number,
		hour = tonumber(hour) :: number,
		min = tonumber(minute) :: number,
		sec = tonumber(second) :: number,
	})
	local offset = os.difftime(os.time(), os.time(os.date("!*t") :: any))
	return localEpoch + offset
end

Permissions.parseIso = parseIso

--- True while the member is under a communication timeout.
function Permissions.isTimedOut(member: Types.Member): boolean
	local until_ = parseIso(member.communication_disabled_until)
	return until_ ~= nil and until_ > os.time()
end

--[[
	Effective permissions for a member in a channel. See the module comment
	for the ordering; every step of it is load-bearing. `userId` is as for
	`forMember`, and here it also finds the member's own overwrite.
]]
function Permissions.forChannel(
	guild: Types.Guild,
	member: Types.Member,
	channel: Types.Channel,
	roles: { [string]: Types.Role }?,
	userId: string?
): Bits
	local id = memberId(member, userId, "forChannel")
	local base = Permissions.forMember(guild, member, roles, id)
	if base:has(Flags.administrator) then
		return Permissions.ALL
	end

	local overwrites = channel.permission_overwrites
	if overwrites ~= nil then
		local everyone, roleAllow, roleDeny, memberOverwrite = nil, Bitfield.empty, Bitfield.empty, nil
		local held: { [string]: boolean } = {}
		for _, roleId in member.roles do
			held[roleId] = true
		end

		for _, overwrite in overwrites do
			if overwrite.id == guild.id then
				everyone = overwrite
			elseif overwrite.type == Const.OverwriteType.ROLE and held[overwrite.id] then
				roleDeny = roleDeny:union(Bitfield.fromString(overwrite.deny))
				roleAllow = roleAllow:union(Bitfield.fromString(overwrite.allow))
			elseif overwrite.type == Const.OverwriteType.MEMBER and id ~= nil and overwrite.id == id then
				memberOverwrite = overwrite
			end
		end

		if everyone ~= nil then
			base = base:without(Bitfield.fromString(everyone.deny)):union(Bitfield.fromString(everyone.allow))
		end
		base = base:without(roleDeny):union(roleAllow)
		if memberOverwrite ~= nil then
			base = base
				:without(Bitfield.fromString(memberOverwrite.deny))
				:union(Bitfield.fromString(memberOverwrite.allow))
		end
	end

	if not base:has(Flags.viewChannel) then
		-- No view means no channel permissions at all, whatever else is set.
		return Bitfield.empty
	end

	if Permissions.isTimedOut(member) then
		-- A timed-out member keeps only the two read permissions.
		return base:intersect(Flags.viewChannel:union(Flags.readMessageHistory))
	end

	return base
end

--[[
	Whether `actor` outranks `target` in the role hierarchy.

	Needed before any moderation action: Discord rejects kicking, banning or
	role-editing someone whose highest role is at or above your own, and the
	guild owner outranks everyone regardless of roles. Checking first turns a
	403 into a sentence the user can act on.

	`actorId` and `targetId` are for members that lack `user` (see
	`memberId`), which is how a resolved interaction member arrives.
]]
function Permissions.outranks(
	guild: Types.Guild,
	actor: Types.Member,
	target: Types.Member,
	roles: { [string]: Types.Role }?,
	actorId: string?,
	targetId: string?
): boolean
	local actorKey = memberId(actor, actorId, "outranks")
	local targetKey = memberId(target, targetId, "outranks")
	if actorKey ~= nil and guild.owner_id == actorKey then
		return true
	end
	if targetKey ~= nil and guild.owner_id == targetKey then
		return false
	end

	local lookup = roles
	if lookup == nil then
		lookup = {}
		for _, role in guild.roles or {} do
			lookup[role.id] = role
		end
	end
	assert(lookup ~= nil)

	local byId = lookup :: { [string]: Types.Role }
	local function highest(member: Types.Member): number
		local best = -1
		for _, roleId in member.roles do
			local role = byId[roleId]
			if role ~= nil and role.position > best then
				best = role.position
			end
		end
		return best
	end

	return highest(actor) > highest(target)
end

return Permissions
