--!strict
--[[
	Read-only lookups: /userinfo, /serverinfo, /avatar, /roleinfo,
	/snowflake, /perms, plus the two right-click context menus.

	These lean on things the library computes rather than fetches: resolved
	interaction data (no extra request for the target user), the event cache
	(no request for roles or channels) and `Permissions.forChannel` (no
	request at all -- Discord does not offer this as an endpoint).
]]
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components
local Const = Discord.Const
local Embed = Discord.Embed
local Permissions = Discord.Permissions
local Snowflake = Discord.Snowflake
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Info = {}

--- `Api.cdn` handles the awkward cases: animated `a_` hashes, and the
--- default avatar for accounts without one, which is chosen differently
--- for legacy discriminators and for migrated usernames.
local function avatarUrl(user: Discord.User, size: number?): string
	return Discord.Api.cdn.userAvatar(user, { size = size or 256 })
end

Info.avatarUrl = avatarUrl

Info.commands = {
	Commands.slash("userinfo", "Everything about a user"):userOption("user", "Whose profile (defaults to you)"),
	Commands.slash("serverinfo", "About this server"):guildOnly(),
	Commands.slash("avatar", "Someone's avatar, full size")
		:userOption("user", "Whose avatar")
		:integerOption("size", "Pixels", { choices = {
			{ name = "128", value = 128 },
			{ name = "512", value = 512 },
			{ name = "1024", value = 1024 },
			{ name = "4096", value = 4096 },
		} }),
	Commands.slash("roleinfo", "About a role"):roleOption("role", "Which role", { required = true }):guildOnly(),
	Commands.slash("snowflake", "Decode a Discord ID into its timestamp")
		:stringOption("id", "The ID", { required = true }),
	Commands.slash("perms", "What someone may do in a channel")
		:userOption("user", "Who (defaults to you)")
		:channelOption("channel", "Where (defaults to here)")
		:guildOnly(),
	Commands.userCommand("Who is this"),
	Commands.messageCommand("Quote this"),
}

local function userEmbed(user: Discord.User, member: Discord.Member?): Discord.Embed
	local embed = Embed.new()
		:setTitle(user.global_name or user.username)
		:setColor(Discord.Color.BLURPLE)
		:setThumbnail(avatarUrl(user, 256))
		:addField("Username", user.username, true)
		:addField("ID", `\`{user.id}\``, true)
		:addField("Bot", if user.bot then "yes" else "no", true)
		:addField("Account created", Util.timestamp(Snowflake.timestamp(user.id), "R"), true)

	if member ~= nil then
		if member.joined_at ~= nil then
			local joined = Permissions.parseIso(member.joined_at)
			if joined ~= nil then
				embed:addField("Joined server", Util.timestamp(joined, "R"), true)
			end
		end
		if member.nick ~= nil then
			embed:addField("Nickname", member.nick, true)
		end
		local mentions = {}
		for _, roleId in member.roles do
			table.insert(mentions, `<@&{roleId}>`)
		end
		if #mentions > 0 then
			embed:addTrimmedField(`Roles ({#mentions})`, table.concat(mentions, " "))
		end
		if Permissions.isTimedOut(member) then
			embed:addField("Timed out", `until {Util.timestamp(Permissions.parseIso(member.communication_disabled_until) :: number, "R")}`, false)
		end
	end
	return embed
end

function Info.register(client: Discord.Client, _ctx: Ctx.Ctx)
	client:command("userinfo", function(ix: Discord.Interaction)
		local user = ix:getUser("user") or ix.user
		local member = ix:getMember("user") or (if ix:opt("user") == nil then ix.member else nil)
		ix:reply({ embeds = { userEmbed(user, member) } })
	end)

	client:command("Who is this", function(ix: Discord.Interaction)
		-- A context menu carries its target in `resolved`, so this needs no
		-- options and no fetch.
		local user = ix:targetUser()
		if user == nil then
			ix:replyEphemeral("Discord did not say who that was.")
			return
		end
		local member = if ix.guildId ~= nil then client.cache:getMember(ix.guildId, user.id) else nil
		ix:replyEphemeral({ embeds = { userEmbed(user, member) } })
	end)

	client:command("Quote this", function(ix: Discord.Interaction)
		local message = ix:targetMessage()
		if message == nil or (message.content == "" and #message.attachments == 0) then
			ix:replyEphemeral("Nothing quotable in that message.")
			return
		end
		local embed = Embed.new()
			:setColor(Discord.Color.GREY)
			:setAuthor(message.author.global_name or message.author.username, avatarUrl(message.author, 64))
			:setDescription(if message.content ~= "" then Util.truncate(message.content :: string, 4000) else "*(no text)*")
			:setFooter(`quoted by {ix.user.username}`)
			:setTimestamp(Snowflake.timestamp(message.id))
		local first = message.attachments[1]
		local kind = if first ~= nil then first.content_type else nil
		if first ~= nil and kind ~= nil and string.sub(kind, 1, 5) == "image" then
			embed:setImage(first.url)
		end
		ix:reply({
			embeds = { embed },
			components = {
				Components.row(
					Components.linkButton(
						"Jump",
						`https://discord.com/channels/{ix.guildId or "@me"}/{message.channel_id}/{message.id}`
					)
				),
			},
		})
	end)

	client:command("serverinfo", function(ix: Discord.Interaction)
		-- `with_counts` is the only way to get member totals without the
		-- privileged members intent.
		local guild = client.api.guilds.get(ix.guildId :: string, true)
		local channels = client.api.guilds.getChannels(ix.guildId :: string)
		local counts: { [number]: number } = {}
		for _, channel in channels do
			counts[channel.type] = (counts[channel.type] or 0) + 1
		end

		local embed = Embed.new()
			:setTitle(guild.name)
			:setColor(Discord.Color.BLURPLE)
			:addField("ID", `\`{guild.id}\``, true)
			:addField("Owner", `<@{guild.owner_id}>`, true)
			:addField("Created", Util.timestamp(Snowflake.timestamp(guild.id), "R"), true)
			:addField("Members", tostring((guild :: any).approximate_member_count or "?"), true)
			:addField("Online", tostring((guild :: any).approximate_presence_count or "?"), true)
			:addField("Roles", tostring(#(guild.roles or {})), true)
			:addField("Text channels", tostring(counts[Const.ChannelType.GUILD_TEXT] or 0), true)
			:addField("Voice channels", tostring(counts[Const.ChannelType.GUILD_VOICE] or 0), true)
			:addField("Categories", tostring(counts[Const.ChannelType.GUILD_CATEGORY] or 0), true)
			:addField("Boosts", `tier {guild.premium_tier or 0} ({guild.premium_subscription_count or 0})`, true)

		local icon, banner = guild.icon, guild.banner
		if icon ~= nil then
			embed:setThumbnail(Discord.Api.cdn.guildIcon(guild.id, icon, { size = 256 }))
		end
		if banner ~= nil then
			embed:setImage(Discord.Api.cdn.guildBanner(guild.id, banner, { size = 1024 }))
		end
		if guild.description ~= nil then
			embed:setDescription(guild.description)
		end
		if guild.features ~= nil and #guild.features > 0 then
			embed:addTrimmedField("Features", table.concat(guild.features, ", "))
		end
		ix:reply({ embeds = { embed } })
	end)

	client:command("avatar", function(ix: Discord.Interaction)
		local user = ix:getUser("user") or ix.user
		local size = ix:opt("size", 512)
		local url = avatarUrl(user, size)
		ix:reply({
			embeds = {
				Embed.new()
					:setTitle(`{user.global_name or user.username}'s avatar`)
					:setColor(Discord.Color.BLURPLE)
					:setImage(url),
			},
			components = { Components.row(Components.linkButton("Open original", url)) },
		})
	end)

	client:command("roleinfo", function(ix: Discord.Interaction)
		local role = ix:getRole("role")
		if role == nil then
			ix:replyEphemeral("Could not resolve that role.")
			return
		end
		local granted = Permissions.list(Permissions.parse(role.permissions))
		local embed = Embed.new()
			:setTitle(role.name)
			:setColor(if role.color ~= 0 then role.color else Discord.Color.GREY)
			:addField("ID", `\`{role.id}\``, true)
			:addField("Position", tostring(role.position), true)
			:addField("Colour", if role.color ~= 0 then string.format("#%06X", role.color) else "none", true)
			:addField("Hoisted", if role.hoist then "yes" else "no", true)
			:addField("Mentionable", if role.mentionable then "yes" else "no", true)
			:addField("Managed by an integration", if role.managed then "yes" else "no", true)
			:addTrimmedField(
				`Permissions ({#granted})`,
				if #granted > 0 then "`" .. table.concat(granted, "`, `") .. "`" else "*none*"
			)
		ix:reply({ embeds = { embed } })
	end)

	client:command("snowflake", function(ix: Discord.Interaction)
		local id = ix:opt("id") :: string
		if not Snowflake.isValid(id) then
			ix:replyEphemeral(`\`{Util.truncate(id, 40)}\` is not a snowflake.`)
			return
		end
		local seconds = Snowflake.timestamp(id)
		ix:reply({
			embeds = {
				Embed.new()
					:setTitle("Snowflake")
					:setColor(Discord.Color.BLURPLE)
					:addField("ID", `\`{id}\``, false)
					:addField("Created", `{Util.timestamp(seconds, "F")} ({Util.timestamp(seconds, "R")})`, false)
					:addField("UTC", Snowflake.isoDate(id), false)
					:setFooter("the high 42 bits are milliseconds since 2015-01-01"),
			},
		})
	end)

	client:command("perms", function(ix: Discord.Interaction)
		local guild = client.cache:getGuild(ix.guildId)
		if guild == nil then
			ix:replyEphemeral("I do not have this guild cached yet -- try again in a moment.")
			return
		end
		-- Cache first, REST second: the cache only holds members seen since
		-- startup, but the answer is identical either way.
		local targetUser = ix:getUser("user") or ix.user
		local member: Discord.Member = ix:getMember("user")
			or client.cache:getMember(guild.id, targetUser.id)
			or client.api.guilds.getMember(guild.id, targetUser.id)
		local channelId = ix:requireChannelId()
		local channel: Discord.Channel = ix:getChannel("channel")
			or client.cache:getChannel(channelId)
			or client.api.channels.get(channelId)

		local effective = Permissions.forChannel(guild, member, channel, client.cache:getRoles(guild.id))
		local names = Permissions.list(effective)
		ix:replyEphemeral({
			embeds = {
				Embed.new()
					:setTitle(`Permissions for {targetUser.username}`)
					:setDescription(`in <#{channel.id}>, computed locally from roles and overwrites`)
					:setColor(Discord.Color.BLURPLE)
					:addTrimmedField(
						`Granted ({#names})`,
						if #names > 0 then "`" .. table.concat(names, "`, `") .. "`" else "*nothing*"
					)
					:addField("Raw bitfield", `\`{effective:toString()}\``, false),
			},
		})
	end)
end

return Info
