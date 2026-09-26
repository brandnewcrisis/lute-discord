--!strict
--[[
	Gateway event handlers: welcomes, reaction roles, prefix commands,
	presence rotation, and a couple of console-only logs.

	The reaction-role handler is the one worth reading. It works from RAW
	gateway events rather than a cache, because a reaction can land on a
	message from years ago that this process has never seen -- and Discord
	sends the reaction event regardless.
]]
local task = require("@lute/task")

local Discord = require("@discord")
local Embed = Discord.Embed
local Log = Discord.Log
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Events = {}

--[[
	The gateway identifies an emoji two different ways, and the reaction-role
	table has to be keyed on the same one the command stored.

	A unicode emoji arrives as the character in `name` with a null `id`; a
	custom one arrives as `name` plus `id`, and only the id is stable -- the
	name can be changed by any admin.
]]
local function emojiKey(emoji: Discord.Emoji?): string
	if emoji == nil then
		return ""
	end
	if emoji.id ~= nil then
		return `{emoji.name}:{emoji.id}`
	end
	return emoji.name or ""
end

function Events.register(client: Discord.Client, ctx: Ctx.Ctx)
	local function memberCount(guildId: string): string
		local guild = client.cache:getGuild(guildId)
		local count = if guild ~= nil then guild.member_count else nil
		return if count ~= nil then tostring(count) else "?"
	end

	----------------------------------------------------------------------
	-- Connection lifecycle
	----------------------------------------------------------------------

	client:on("ready", function(ready: Discord.Ready)
		Log.info(`logged in as {ready.user.username}#{ready.user.discriminator} ({ready.user.id})`)
		Log.info(`invite me: https://discord.com/oauth2/authorize?client_id={ready.user.id}&permissions=1497132340822&scope=bot%20applications.commands`)

		-- Presence has to be set over the gateway, not REST -- there is no
		-- REST route for it. Rotating it is a cheap sign of life.
		local rotation = {
			{ "watching", "the kitchen sink" },
			{ "playing", "with Lute" },
			{ "listening", "/help" },
		}
		task.spawn(function()
			local index = 0
			while client.running do
				index = index % #rotation + 1
				local entry = rotation[index]
				client:setPresence(Discord.Client.presence(entry[1] :: string, entry[2] :: string))
				task.wait(300)
			end
		end)
	end)

	client:on("guildCreate", function(guild: Discord.Guild)
		Log.info(`joined or synced guild {guild.name} ({guild.id}) with {guild.member_count or "?"} members`)
	end)

	client:on("error", function(_err: string, context: string)
		-- Everything is already logged with a traceback; this hook is where
		-- a real bot would forward to Sentry or a log channel.
		Log.debug(`error hook fired for {tostring(context)}`)
	end)

	----------------------------------------------------------------------
	-- Welcomes
	----------------------------------------------------------------------

	--[[
		Needs the GUILD_MEMBERS privileged intent. Without it this event
		never fires, which is why the bot logs its intent set at startup --
		"my welcome handler does nothing" has exactly one cause and it is
		never the handler.
	]]
	client:on("guildMemberAdd", function(member: Discord.GuildMemberEvent)
		local channelId = (ctx.store:get("welcomeChannels", {}) :: any)[member.guild_id]
		local user = member.user
		if channelId == nil or user == nil then
			return
		end
		pcall(function()
			client:send(channelId, {
				embeds = {
					Embed.new()
						:setTitle(`Welcome, {user.username}`)
						:setDescription(`You are member number {memberCount(member.guild_id)}.`)
						:setColor(Discord.Color.GREEN)
						:setThumbnail(require("@bot/commands/info").avatarUrl(user, 128))
						:setFooter(`account created {Util.duration(os.time() - Discord.Snowflake.timestamp(user.id))} ago`),
				},
			})
		end)
	end)

	----------------------------------------------------------------------
	-- Reaction roles
	----------------------------------------------------------------------

	local function reactionRole(payload: Discord.MessageReactionAdd | Discord.MessageReactionRemove, add: boolean)
		local mapping = (ctx.store:get("reactionRoles", {}) :: any)[payload.message_id]
		if mapping == nil then
			return
		end
		local entry = mapping[emojiKey(payload.emoji)]
		local guildId = payload.guild_id
		local bot = client.user
		if entry == nil or guildId == nil or (bot ~= nil and payload.user_id == bot.id) then
			return
		end
		local roleId: string = entry.roleId

		local ok, err = pcall(function()
			if add then
				client.api.guilds.addMemberRole(guildId, payload.user_id, roleId, "reaction role")
			else
				client.api.guilds.removeMemberRole(guildId, payload.user_id, roleId, "reaction role")
			end
		end)
		if not ok then
			-- The usual causes: the role was deleted, or it was moved above
			-- the bot's own highest role after the mapping was made.
			Log.warn(`reaction role failed for {payload.user_id}: {tostring(err)}`)
		end
	end

	client:on("messageReactionAdd", function(payload: Discord.MessageReactionAdd)
		reactionRole(payload, true)
	end)

	client:on("messageReactionRemove", function(payload: Discord.MessageReactionRemove)
		reactionRole(payload, false)
	end)

	----------------------------------------------------------------------
	-- Prefix commands
	----------------------------------------------------------------------

	--[[
		Old-style `!command` handling.

		Without the MESSAGE_CONTENT privileged intent, `content` is empty for
		every message except DMs to the bot and messages that mention it --
		so these still work when someone pings the bot, and silently do
		nothing otherwise. Slash commands have no such restriction, which is
		the real reason Discord pushed everyone to them.
	]]
	client:on("messageCreate", function(message: Discord.Message)
		if message.author == nil or message.author.bot then
			return
		end
		local content = message.content or ""
		if string.sub(content, 1, #ctx.config.prefix) ~= ctx.config.prefix then
			return
		end

		local name, rest = string.match(string.sub(content, #ctx.config.prefix + 1), "^(%S+)%s*(.*)$")
		if name == nil then
			return
		end
		name = string.lower(name :: string)

		if name == "ping" then
			local before = Util.now()
			local sent = client:reply(message, "Pinging...")
			client.api.channels.editMessage(message.channel_id, sent.id, {
				content = `Pong: {math.floor(Util.since(before) * 1000)} ms round trip, `
					.. `{math.floor(client:latency() * 1000)} ms gateway.`,
			})
		elseif name == "echo" then
			if rest == "" then
				client:reply(message, "Give me something to echo.")
				return
			end
			client:reply(message, {
				content = Util.escapeMarkdown(rest :: string),
				allowed_mentions = Discord.Payload.NO_MENTIONS,
			})
		elseif name == "react" then
			client.api.channels.addReaction(message.channel_id, message.id, "\u{1f44b}")
		elseif name == "help" then
			client:reply(message, "Everything else is a slash command -- type `/` and look for me.")
		end
	end)

	client:on("messageDelete", function(payload: Discord.MessageDelete)
		Log.debug(`message {payload.id} deleted in {payload.channel_id}`)
	end)
end

return Events
