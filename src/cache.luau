--!strict
--[[
	An in-memory mirror of what the gateway has told us.

	The gateway sends a full GUILD_CREATE for every guild on connect and a
	delta for every change afterwards, so the state is already arriving --
	keeping it costs nothing extra and turns "what colour is this role" from
	a REST round trip into a table lookup. The permission checks in
	`@discord/permissions` need roles and channel overwrites for every check,
	so without a cache a single moderation command becomes three API calls.

	What is NOT cached: members and users beyond those seen in events, because
	filling those needs the GUILD_MEMBERS privileged intent and unbounded
	memory. For anyone else, fetch with `client.api.guilds.getMember` (or
	`client:fetchMembers` in bulk, which caches what it gets).

	Everything is keyed by snowflake string. The cache is per-client and is
	never shared, so no locking.
]]
local Types = require("@discord/types")

local Cache = {}
Cache.__index = Cache

export type Cache = typeof(setmetatable(
	{} :: {
		enabled: boolean,
		guilds: { [string]: Types.Guild },
		channels: { [string]: Types.Channel },
		roles: { [string]: { [string]: Types.Role } },
		members: { [string]: { [string]: Types.Member } },
		users: { [string]: Types.User },
		--- Which guild a channel belongs to, so a channel id is enough to
		--- resolve a guild -- gateway events often carry only the former.
		channelGuild: { [string]: string },
		self: Types.User?,
	},
	{} :: typeof(Cache)
))

function Cache.new(enabled: boolean): Cache
	return setmetatable({
		enabled = enabled,
		guilds = {},
		channels = {},
		roles = {},
		members = {},
		users = {},
		channelGuild = {},
		self = nil :: Types.User?,
	}, Cache)
end

function Cache.putUser(self: Cache, user: Types.User?)
	if not self.enabled or user == nil then
		return
	end
	self.users[user.id] = user
end

function Cache.putChannel(self: Cache, channel: Types.Channel, guildId: string?)
	if not self.enabled then
		return
	end
	local owner = channel.guild_id or guildId
	if owner ~= nil then
		channel.guild_id = owner
		self.channelGuild[channel.id] = owner
	end
	self.channels[channel.id] = channel
end

--[[
	Stores a full guild (GUILD_CREATE) and fans it out into the channel,
	thread, role and member maps.

	An UNAVAILABLE guild -- one caught in an outage, sent as a bare
	`{ id, unavailable = true }` -- is not stored as a guild: it has no name,
	no roles, nothing a caller can use, and storing it would wipe the role
	map of a guild we already knew. A known guild is just flagged instead,
	and keeps its data until Discord sends it again.
]]
function Cache.putGuild(self: Cache, guild: Types.Guild)
	if not self.enabled then
		return
	end
	if guild.unavailable == true then
		local known = self.guilds[guild.id]
		if known ~= nil then
			known.unavailable = true
		end
		return
	end
	self.guilds[guild.id] = guild

	-- A fresh GUILD_CREATE is the complete channel list. Anything deleted
	-- while the guild was unavailable never got a CHANNEL_DELETE, so drop
	-- what we knew before re-adding what is actually there.
	for channelId, owner in self.channelGuild do
		if owner == guild.id then
			self.channels[channelId] = nil
			self.channelGuild[channelId] = nil
		end
	end

	local roles = {}
	for _, role in guild.roles or {} do
		roles[role.id] = role
	end
	self.roles[guild.id] = roles

	for _, channel in (guild :: any).channels or {} do
		Cache.putChannel(self, channel, guild.id)
	end
	-- Active threads ride along in GUILD_CREATE and are not repeated as
	-- THREAD_CREATE, so this is the only chance to learn them.
	for _, thread in (guild :: any).threads or {} do
		Cache.putChannel(self, thread, guild.id)
	end
	for _, member in (guild :: any).members or {} do
		Cache.putMember(self, guild.id, member)
	end
end

-- Fields only GUILD_CREATE carries. A GUILD_UPDATE omits them, so they are
-- carried over from the cached guild rather than lost.
local CREATE_ONLY = {
	"channels",
	"members",
	"threads",
	"member_count",
	"joined_at",
	"large",
	"voice_states",
	"presences",
	"stage_instances",
	"guild_scheduled_events",
	"soundboard_sounds",
}

--[[
	Applies a GUILD_UPDATE.

	The update is the guild's full own state but none of GUILD_CREATE's
	extras, so it REPLACES the guild and then has those extras carried over.
	Merging instead would be wrong in the other direction: a field Discord
	cleared arrives as `null`, which decoding turns into an absent key, and
	a merge would keep the stale value -- an icon that was removed, a system
	channel that was unset.
]]
function Cache.patchGuild(self: Cache, patch: Types.Guild)
	if not self.enabled then
		return
	end
	local known = self.guilds[patch.id]
	if known == nil then
		Cache.putGuild(self, patch)
		return
	end
	local fresh: Types.Guild = table.clone(patch)
	for _, key in CREATE_ONLY do
		if fresh[key] == nil then
			fresh[key] = known[key]
		end
	end
	fresh.unavailable = nil
	self.guilds[patch.id] = fresh
	local roles = patch.roles
	if roles ~= nil then
		local map = {}
		for _, role in roles do
			map[role.id] = role
		end
		self.roles[patch.id] = map
	end
end

--- Replaces a guild's emoji list (GUILD_EMOJIS_UPDATE sends the whole set).
function Cache.setEmojis(self: Cache, guildId: string, emojis: { Types.Emoji })
	local guild = self.guilds[guildId]
	if self.enabled and guild ~= nil then
		guild.emojis = emojis
	end
end

--- Replaces a guild's sticker list (GUILD_STICKERS_UPDATE sends the whole set).
function Cache.setStickers(self: Cache, guildId: string, stickers: { Types.Sticker })
	local guild = self.guilds[guildId]
	if self.enabled and guild ~= nil then
		guild.stickers = stickers
	end
end

local THREAD_TYPES = { [10] = true, [11] = true, [12] = true }

--[[
	Applies a THREAD_LIST_SYNC: the full set of active threads for the
	listed parent channels (or the whole guild when `channelIds` is nil).

	The sync is authoritative -- a cached thread that is not in it has been
	archived or deleted while we were away -- so threads under those parents
	are dropped before the fresh list goes in. Discord includes parents with
	no active threads precisely so their stale threads can be cleared.
]]
function Cache.syncThreads(self: Cache, guildId: string, channelIds: { string }?, threads: { Types.Channel })
	if not self.enabled then
		return
	end
	local parents: { [string]: boolean }? = nil
	if channelIds ~= nil then
		local set = {}
		for _, id in channelIds do
			set[id] = true
		end
		parents = set
	end
	for id, channel in self.channels do
		if self.channelGuild[id] == guildId and THREAD_TYPES[channel.type] then
			local parent = channel.parent_id
			if parents == nil or (parent ~= nil and parents[parent]) then
				self.channels[id] = nil
				self.channelGuild[id] = nil
			end
		end
	end
	for _, thread in threads do
		Cache.putChannel(self, thread, guildId)
	end
end

function Cache.putMember(self: Cache, guildId: string, member: Types.Member)
	if not self.enabled then
		return
	end
	local user = member.user
	if user == nil then
		return
	end
	local guildMembers = self.members[guildId]
	if guildMembers == nil then
		guildMembers = {}
		self.members[guildId] = guildMembers
	end
	assert(guildMembers ~= nil)
	guildMembers[user.id] = member
	Cache.putUser(self, user)
end

--[[
	Applies a GUILD_MEMBER_UPDATE.

	The update is the whole member except `deaf` and `mute` (and, rarely,
	`joined_at`), so it replaces the cached one and carries those over. A
	merge would keep fields Discord cleared: `"nick": null` and a lifted
	timeout's `"communication_disabled_until": null` decode to absent keys,
	and the member would keep the old nickname and still read as timed out.
]]
function Cache.patchMember(self: Cache, guildId: string, patch: Types.Member)
	local user = patch.user
	if not self.enabled or user == nil then
		return
	end
	local known = Cache.getMember(self, guildId, user.id)
	local fresh: Types.Member = table.clone(patch)
	if known ~= nil then
		for _, key in { "deaf", "mute", "joined_at" } do
			if fresh[key] == nil then
				fresh[key] = known[key]
			end
		end
	end
	Cache.putMember(self, guildId, fresh)
end

function Cache.removeMember(self: Cache, guildId: string, userId: string)
	local guildMembers = self.members[guildId]
	if guildMembers ~= nil then
		guildMembers[userId] = nil
	end
end

--- Records the bot's own user (READY, USER_UPDATE).
function Cache.setSelf(self: Cache, user: Types.User?)
	if user == nil then
		return
	end
	self.self = user
	Cache.putUser(self, user)
end

function Cache.putRole(self: Cache, guildId: string, role: Types.Role)
	if not self.enabled then
		return
	end
	local guildRoles = self.roles[guildId]
	if guildRoles == nil then
		guildRoles = {}
		self.roles[guildId] = guildRoles
	end
	assert(guildRoles ~= nil)
	guildRoles[role.id] = role

	-- The guild object carries its own role array; keep the two in step or
	-- permission computation that walks `guild.roles` sees stale data.
	local guild = self.guilds[guildId]
	local list = if guild ~= nil then guild.roles else nil
	if list ~= nil then
		for index, existing in list do
			if existing.id == role.id then
				list[index] = role
				return
			end
		end
		table.insert(list, role)
	end
end

function Cache.removeRole(self: Cache, guildId: string, roleId: string)
	local guildRoles = self.roles[guildId]
	if guildRoles ~= nil then
		guildRoles[roleId] = nil
	end
	local guild = self.guilds[guildId]
	local list = if guild ~= nil then guild.roles else nil
	if list ~= nil then
		for index, existing in list do
			if existing.id == roleId then
				table.remove(list, index)
				break
			end
		end
	end
end

function Cache.removeGuild(self: Cache, guildId: string)
	self.guilds[guildId] = nil
	self.roles[guildId] = nil
	self.members[guildId] = nil
	for channelId, owner in self.channelGuild do
		if owner == guildId then
			self.channels[channelId] = nil
			self.channelGuild[channelId] = nil
		end
	end
end

function Cache.removeChannel(self: Cache, channelId: string)
	self.channels[channelId] = nil
	self.channelGuild[channelId] = nil
end

function Cache.getGuild(self: Cache, guildId: string?): Types.Guild?
	return if guildId ~= nil then self.guilds[guildId] else nil
end

function Cache.getChannel(self: Cache, channelId: string?): Types.Channel?
	return if channelId ~= nil then self.channels[channelId] else nil
end

function Cache.getRole(self: Cache, guildId: string, roleId: string): Types.Role?
	local guildRoles = self.roles[guildId]
	return if guildRoles ~= nil then guildRoles[roleId] else nil
end

function Cache.getRoles(self: Cache, guildId: string): { [string]: Types.Role }
	return self.roles[guildId] or {}
end

function Cache.getMember(self: Cache, guildId: string, userId: string): Types.Member?
	local guildMembers = self.members[guildId]
	return if guildMembers ~= nil then guildMembers[userId] else nil
end

function Cache.getUser(self: Cache, userId: string): Types.User?
	return self.users[userId]
end

--- Rough size, for a `/stats` command.
function Cache.stats(self: Cache): { guilds: number, channels: number, roles: number, members: number, users: number }
	local function count(map: any): number
		local total = 0
		for _ in map do
			total += 1
		end
		return total
	end
	local roles, members = 0, 0
	for _, guildRoles in self.roles do
		roles += count(guildRoles)
	end
	for _, guildMembers in self.members do
		members += count(guildMembers)
	end
	return {
		guilds = count(self.guilds),
		channels = count(self.channels),
		roles = roles,
		members = members,
		users = count(self.users),
	}
end

return Cache
