--!strict
--[[
	Moderation: /kick, /ban, /unban, /timeout, /purge, /slowmode, /nick.

	Every one of these checks three things before calling the API, in this
	order, because each produces a different and more useful message than the
	403 Discord would return:

	  1. does the CALLER hold the permission (Discord's default-permission
	     gate is a UI hint that server admins can override, not a check),
	  2. do I hold it,
	  3. does the caller -- and do I -- outrank the target in the role
	     hierarchy, which is a separate rule from permissions and the one
	     that catches people out.

	Everything that changes the guild passes an audit-log reason. A
	moderation action with no trail is not much better than no action.
]]
local Discord = require("@discord")
local Commands = Discord.Commands
local Embed = Discord.Embed
local Permissions = Discord.Permissions
local Snowflake = Discord.Snowflake
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Moderation = {}

Moderation.commands = {
	Commands.slash("kick", "Remove a member from the server")
		:userOption("user", "Who", { required = true })
		:stringOption("reason", "Shown in the audit log")
		:defaultPermissions("kickMembers")
		:guildOnly(),
	Commands.slash("ban", "Ban a member")
		:userOption("user", "Who", { required = true })
		:stringOption("reason", "Shown in the audit log")
		:integerOption("purge_hours", "Also delete their messages from the last N hours", { min = 0, max = 168 })
		:defaultPermissions("banMembers")
		:guildOnly(),
	Commands.slash("unban", "Lift a ban")
		:stringOption("user_id", "The banned user's ID", { required = true })
		:stringOption("reason", "Shown in the audit log")
		:defaultPermissions("banMembers")
		:guildOnly(),
	Commands.slash("timeout", "Mute a member for a while")
		:userOption("user", "Who", { required = true })
		:integerOption("minutes", "0 to lift the timeout", { required = true, min = 0, max = 40320 })
		:stringOption("reason", "Shown in the audit log")
		:defaultPermissions("moderateMembers")
		:guildOnly(),
	Commands.slash("purge", "Bulk delete recent messages")
		:integerOption("count", "How many to scan, 2 to 100", { required = true, min = 2, max = 100 })
		:userOption("user", "Only delete this person's messages")
		:defaultPermissions("manageMessages")
		:guildOnly(),
	Commands.slash("slowmode", "Set this channel's slow mode")
		:integerOption("seconds", "0 to turn it off", { required = true, min = 0, max = 21600 })
		:defaultPermissions("manageChannels")
		:guildOnly(),
	Commands.slash("nick", "Change a member's nickname")
		:userOption("user", "Who", { required = true })
		:stringOption("nickname", "Leave empty to clear it")
		:defaultPermissions("manageNicknames")
		:guildOnly(),
}

--[[
	The shared preflight.

	Returns the target member on success, or nil after having already
	answered the interaction with the specific reason it cannot proceed.
]]
local function preflight(
	client: Discord.Client,
	ix: Discord.Interaction,
	permission: string,
	needsHierarchy: boolean
): Discord.Member?
	if ix.guildId == nil then
		ix:replyEphemeral("That only works in a server.")
		return nil
	end

	-- Discord precomputes both of these and ships them on the payload.
	if not Permissions.has(ix:memberPermissions(), permission) then
		ix:replyEphemeral(`You need the **{permission}** permission for that.`)
		return nil
	end
	if not Permissions.has(ix:appPermissions(), permission) then
		ix:replyEphemeral(`I do not have the **{permission}** permission in this server.`)
		return nil
	end

	local target = ix:getMember("user")
	local targetUser = ix:getUser("user")
	if targetUser == nil then
		ix:replyEphemeral("Could not resolve that user.")
		return nil
	end
	local bot = client.user
	if bot ~= nil and targetUser.id == bot.id then
		ix:replyEphemeral("I would rather not do that to myself.")
		return nil
	end
	if target == nil then
		ix:replyEphemeral(`<@{targetUser.id}> is not in this server.`)
		return nil
	end

	if needsHierarchy then
		local guild = client.cache:getGuild(ix.guildId)
		if guild == nil then
			-- Without the guild there is no hierarchy to check, and guessing
			-- is worse than stopping.
			ix:replyEphemeral("I do not have this server cached yet -- try again in a moment.")
			return nil
		end
		local roles = client.cache:getRoles(guild.id)
		local actor = ix.member
		if actor ~= nil and not Permissions.outranks(guild, actor, target, roles) then
			ix:replyEphemeral("Their highest role is above yours, so you cannot act on them.")
			return nil
		end
		local me = if bot ~= nil then client.cache:getMember(guild.id, bot.id) else nil
		if me ~= nil and not Permissions.outranks(guild, me, target, roles) then
			ix:replyEphemeral("Their highest role is above mine. Move my role higher and try again.")
			return nil
		end
	end

	return target
end

local function actionEmbed(title: string, target: Discord.User, moderator: Discord.User, reason: string): Discord.Embed
	return Embed.new()
		:setTitle(title)
		:setColor(Discord.Color.RED)
		:addField("Member", `<@{target.id}> (\`{target.id}\`)`, false)
		:addField("Moderator", `<@{moderator.id}>`, true)
		:addField("Reason", Util.truncate(reason, 900), false)
		:setTimestamp()
end

function Moderation.register(client: Discord.Client, _ctx: Ctx.Ctx)
	client:command("kick", function(ix: Discord.Interaction)
		if preflight(client, ix, "kickMembers", true) == nil then
			return
		end
		local user = ix:requireUser("user")
		local reason = ix:opt("reason", "no reason given")
		-- Tell them before removing them: after the kick there is no shared
		-- guild, and a bot cannot DM a stranger.
		client:dm(user.id, `You were kicked from a server. Reason: {reason}`)
		client.api.guilds.kickMember(ix:requireGuildId(), user.id, `{ix.user.username}: {reason}`)
		ix:reply({ embeds = { actionEmbed("Kicked", user, ix.user, reason) } })
	end)

	client:command("ban", function(ix: Discord.Interaction)
		-- A ban does not require the target to be a member, but when they
		-- are, the hierarchy still applies.
		local user = ix:requireUser("user")
		if user == nil then
			ix:replyEphemeral("Could not resolve that user.")
			return
		end
		if ix:getMember("user") ~= nil then
			if preflight(client, ix, "banMembers", true) == nil then
				return
			end
		elseif not Permissions.has(ix:memberPermissions(), "banMembers") then
			ix:replyEphemeral("You need the **banMembers** permission for that.")
			return
		end

		local reason = ix:opt("reason", "no reason given")
		local hours = ix:opt("purge_hours", 0)
		client:dm(user.id, `You were banned from a server. Reason: {reason}`)
		client.api.guilds.banMember(
			ix:requireGuildId(),
			user.id,
			{ deleteMessageSeconds = hours * 3600 },
			`{ix.user.username}: {reason}`
		)
		local embed = actionEmbed("Banned", user, ix.user, reason)
		if hours > 0 then
			embed:addField("Messages purged", `last {hours}h`, true)
		end
		ix:reply({ embeds = { embed } })
	end)

	client:command("unban", function(ix: Discord.Interaction)
		local id = ix:opt("user_id")
		if not Snowflake.isValid(id) then
			ix:replyEphemeral("That is not a user ID. Right-click the user in the ban list and Copy ID.")
			return
		end
		if not Permissions.has(ix:memberPermissions(), "banMembers") then
			ix:replyEphemeral("You need the **banMembers** permission for that.")
			return
		end
		local ok, err = pcall(function()
			client.api.guilds.unbanMember(ix:requireGuildId(), id, `{ix.user.username}: unban`)
		end)
		if not ok then
			if Discord.Error.isUnknownResource(err) then
				ix:replyEphemeral("That user is not banned here.")
			else
				error(err)
			end
			return
		end
		ix:reply(`Unbanned \`{id}\`.`)
	end)

	client:command("timeout", function(ix: Discord.Interaction)
		local target = preflight(client, ix, "moderateMembers", true)
		if target == nil then
			return
		end
		local user = ix:requireUser("user")
		local minutes: number = ix:opt("minutes")
		local reason = ix:opt("reason", "no reason given")

		-- Discord takes an absolute ISO timestamp, and null to lift it.
		local until_: any = if minutes > 0
			then (os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + minutes * 60) :: string)
			else Discord.Json.null
		client.api.guilds.editMember(
			ix:requireGuildId(),
			user.id,
			{ communication_disabled_until = until_ },
			`{ix.user.username}: {reason}`
		)

		if minutes == 0 then
			ix:reply(`Timeout lifted for <@{user.id}>.`)
			return
		end
		ix:reply({
			embeds = {
				actionEmbed("Timed out", user, ix.user, reason)
					:addField("Until", Util.timestamp(os.time() + minutes * 60, "R"), true),
			},
		})
	end)

	client:command("purge", function(ix: Discord.Interaction)
		if not Permissions.has(ix:memberPermissions(), "manageMessages") then
			ix:replyEphemeral("You need the **manageMessages** permission for that.")
			return
		end
		if not Permissions.has(ix:appPermissions(), "manageMessages") then
			ix:replyEphemeral("I do not have **manageMessages** in this channel.")
			return
		end
		-- Fetching and deleting takes longer than three seconds often enough
		-- that deferring is the only safe choice.
		ix:defer(true)

		local count = ix:opt("count")
		local onlyUser = ix:getUser("user")
		local messages = client.api.channels.getMessages(ix:requireChannelId(), { limit = count })

		-- Bulk delete refuses anything older than two weeks. Filtering here
		-- means the command reports "12 were too old" instead of failing.
		local ids = {}
		local tooOld = 0
		for _, message in messages do
			if onlyUser == nil or message.author.id == onlyUser.id then
				if Snowflake.age(message.id) > 14 * 86400 then
					tooOld += 1
				else
					table.insert(ids, message.id)
				end
			end
		end

		if #ids == 0 then
			ix:editReply(`Nothing to delete.{if tooOld > 0 then ` ({tooOld} were over 14 days old.)` else ""}`)
			return
		end
		if #ids == 1 then
			-- Bulk delete needs two or more; one is a plain delete.
			client.api.channels.deleteMessage(ix:requireChannelId(), ids[1], `purge by {ix.user.username}`)
		else
			client.api.channels.bulkDeleteMessages(ix:requireChannelId(), ids, `purge by {ix.user.username}`)
		end
		ix:editReply(
			`Deleted {#ids} message(s).{if tooOld > 0 then ` {tooOld} were over 14 days old and cannot be bulk deleted.` else ""}`
		)
	end)

	client:command("slowmode", function(ix: Discord.Interaction)
		if not Permissions.has(ix:memberPermissions(), "manageChannels") then
			ix:replyEphemeral("You need the **manageChannels** permission for that.")
			return
		end
		local seconds = ix:opt("seconds")
		client.api.channels.edit(
			ix:requireChannelId(),
			{ rate_limit_per_user = seconds },
			`slowmode by {ix.user.username}`
		)
		ix:reply(
			if seconds == 0
				then "Slow mode off."
				else `Slow mode set to {Util.duration(seconds)} between messages.`
		)
	end)

	client:command("nick", function(ix: Discord.Interaction)
		local target = preflight(client, ix, "manageNicknames", true)
		if target == nil then
			return
		end
		local user = ix:requireUser("user")
		local nickname = ix:opt("nickname")
		client.api.guilds.editMember(
			ix:requireGuildId(),
			user.id,
			-- An explicit null clears it; omitting the field would leave it
			-- unchanged, which is the subtle difference `Json.null` exists for.
			{ nick = if nickname ~= nil then nickname else Discord.Json.null },
			`nickname by {ix.user.username}`
		)
		ix:reply(
			if nickname ~= nil
				then `<@{user.id}> is now **{Util.escapeMarkdown(nickname)}**.`
				else `Cleared <@{user.id}>'s nickname.`
		)
	end)
end

return Moderation
