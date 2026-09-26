--!strict
--[[
	Utility: /weather, /tag, /remind, /say, /upload, /colour, /reactionrole.

	  /weather      autocomplete, answered from a local list
	  /tag          subcommands plus persistence to disk
	  /remind       scheduled work with `task.delay`
	  /say          webhooks -- how a bot speaks under another name
	  /upload       file attachments, i.e. multipart bodies
	  /colour       a generated SVG, uploaded from memory
	  /reactionrole reaction roles, wired to raw gateway events
]]
local task = require("@lute/task")

local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components
local Embed = Discord.Embed
local Permissions = Discord.Permissions
local Snowflake = Discord.Snowflake
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Utility = {}

-- A stand-in for a real API, so the example runs with no network beyond
-- Discord and no key to configure.
local CITIES = {
	{ name = "Amsterdam", temp = 12, sky = "drizzle", emoji = "\u{1f327}\u{fe0f}" },
	{ name = "Austin", temp = 29, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "Berlin", temp = 9, sky = "overcast", emoji = "\u{2601}\u{fe0f}" },
	{ name = "Cairo", temp = 33, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "Cape Town", temp = 18, sky = "windy", emoji = "\u{1f4a8}" },
	{ name = "Chicago", temp = 4, sky = "snow", emoji = "\u{2744}\u{fe0f}" },
	{ name = "Dublin", temp = 11, sky = "rain", emoji = "\u{1f327}\u{fe0f}" },
	{ name = "Helsinki", temp = -3, sky = "snow", emoji = "\u{2744}\u{fe0f}" },
	{ name = "Lisbon", temp = 19, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "London", temp = 10, sky = "cloudy", emoji = "\u{2601}\u{fe0f}" },
	{ name = "Melbourne", temp = 22, sky = "showers", emoji = "\u{1f326}\u{fe0f}" },
	{ name = "Mexico City", temp = 24, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "Nairobi", temp = 25, sky = "cloudy", emoji = "\u{2601}\u{fe0f}" },
	{ name = "Reykjavik", temp = 2, sky = "sleet", emoji = "\u{1f328}\u{fe0f}" },
	{ name = "Seoul", temp = 7, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "Singapore", temp = 31, sky = "thunderstorms", emoji = "\u{26c8}\u{fe0f}" },
	{ name = "Sydney", temp = 26, sky = "clear", emoji = "\u{2600}\u{fe0f}" },
	{ name = "Tokyo", temp = 16, sky = "cloudy", emoji = "\u{2601}\u{fe0f}" },
	{ name = "Toronto", temp = 1, sky = "flurries", emoji = "\u{2744}\u{fe0f}" },
	{ name = "Vancouver", temp = 8, sky = "rain", emoji = "\u{1f327}\u{fe0f}" },
}

Utility.commands = {
	Commands.slash("weather", "Look up a city (the option autocompletes)")
		:stringOption("city", "Start typing", { required = true, autocomplete = true }),
	Commands.slash("tag", "Short saved snippets, per server")
		:subcommand("get", "Show a tag", function(sub)
			sub:stringOption("name", "Which tag", { required = true, autocomplete = true })
		end)
		:subcommand("set", "Create or replace a tag", function(sub)
			sub:stringOption("name", "Tag name", { required = true })
			sub:stringOption("content", "What it says", { required = true })
		end)
		:subcommand("delete", "Remove a tag", function(sub)
			sub:stringOption("name", "Which tag", { required = true, autocomplete = true })
		end)
		:subcommand("list", "Every tag on this server")
		:guildOnly(),
	Commands.slash("remind", "Remind you later, here")
		:integerOption("minutes", "In how many minutes", { required = true, min = 1, max = 1440 })
		:stringOption("about", "What about", { required = true }),
	Commands.slash("say", "Speak through a webhook, under any name")
		:stringOption("message", "What to say", { required = true })
		:stringOption("name", "The name to speak under")
		:defaultPermissions("manageWebhooks")
		:guildOnly(),
	Commands.slash("upload", "Send a generated file")
		:stringOption("kind", "What to generate", {
			required = true,
			choices = {
				{ name = "This server's roles, as CSV", value = "roles" },
				{ name = "A README", value = "readme" },
			},
		})
		:guildOnly(),
	Commands.slash("colour", "Render a hex colour as an image")
		:stringOption("hex", "For example #5865F2", { required = true }),
	Commands.slash("reactionrole", "Give a role to anyone who reacts to a message")
		:stringOption("message_id", "The message to watch", { required = true })
		:stringOption("emoji", "The reaction, e.g. \u{2705}", { required = true })
		:roleOption("role", "The role to hand out", { required = true })
		:defaultPermissions("manageRoles")
		:guildOnly(),
}

function Utility.register(client: Discord.Client, ctx: Ctx.Ctx)
	----------------------------------------------------------------------
	-- Autocomplete
	----------------------------------------------------------------------

	--[[
		Autocomplete fires on every keystroke and shares the same three
		second budget, so the answer has to come from something already in
		memory. Hitting a remote API here is the usual reason autocomplete
		"stops working" under load.
	]]
	client:autocomplete("weather", function(ix: Discord.Interaction)
		local _, typed = ix:focused()
		local needle = string.lower(tostring(typed or ""))
		local choices = {}
		for _, city in CITIES do
			if needle == "" or string.find(string.lower(city.name), needle, 1, true) ~= nil then
				table.insert(choices, { name = `{city.emoji} {city.name}`, value = city.name })
			end
		end
		ix:autocomplete(choices)
	end)

	client:command("weather", function(ix: Discord.Interaction)
		local wanted = string.lower(ix:opt("city"))
		for _, city in CITIES do
			if string.lower(city.name) == wanted then
				ix:reply({
					embeds = {
						Embed.new()
							:setTitle(`{city.emoji} {city.name}`)
							:setDescription(`**{city.temp}\u{b0}C**, {city.sky}`)
							:setColor(if city.temp > 20 then Discord.Color.YELLOW else Discord.Color.BLURPLE)
							:setFooter("invented data -- swap CITIES for a real API"),
					},
				})
				return
			end
		end
		ix:replyEphemeral(`I have no data for "{Util.escapeMarkdown(ix:opt("city"))}".`)
	end)

	----------------------------------------------------------------------
	-- Tags
	----------------------------------------------------------------------

	local function tagsFor(guildId: string): { [string]: any }
		local all = ctx.store:get("tags", {})
		if all[guildId] == nil then
			all[guildId] = {}
			ctx.store:set("tags", all)
		end
		return all[guildId]
	end

	client:autocomplete("tag", function(ix: Discord.Interaction)
		local _, typed = ix:focused()
		local needle = string.lower(tostring(typed or ""))
		local choices = {}
		for name in tagsFor(ix:requireGuildId()) do
			if needle == "" or string.find(string.lower(name), needle, 1, true) ~= nil then
				table.insert(choices, { name = name, value = name })
			end
		end
		table.sort(choices, function(a: any, b: any): boolean
			return a.name < b.name
		end)
		ix:autocomplete(choices)
	end)

	client:command("tag get", function(ix: Discord.Interaction)
		local tag = tagsFor(ix:requireGuildId())[ix:opt("name")]
		if tag == nil then
			ix:replyEphemeral(`No tag called \`{Util.truncate(ix:opt("name"), 40)}\`.`)
			return
		end
		ix:reply({ content = tag.content, allowed_mentions = Discord.Payload.NO_MENTIONS })
	end)

	client:command("tag set", function(ix: Discord.Interaction)
		if not Permissions.has(ix:memberPermissions(), "manageMessages") then
			ix:replyEphemeral("You need **manageMessages** to edit tags.")
			return
		end
		local name = string.lower(ix:opt("name"))
		if #name > 32 then
			ix:replyEphemeral("Tag names are 32 characters at most.")
			return
		end
		local all = ctx.store:get("tags", {})
		all[ix.guildId] = all[ix.guildId] or {}
		all[ix.guildId][name] = {
			content = Util.truncate(ix:opt("content"), 1800),
			author = ix.user.id,
			created = os.time(),
		}
		ctx.store:set("tags", all)
		ix:reply(`Saved tag \`{name}\`. Anyone can read it with \`/tag get\`.`)
	end)

	client:command("tag delete", function(ix: Discord.Interaction)
		if not Permissions.has(ix:memberPermissions(), "manageMessages") then
			ix:replyEphemeral("You need **manageMessages** to delete tags.")
			return
		end
		local all = ctx.store:get("tags", {})
		local guildTags = all[ix.guildId] or {}
		local name = string.lower(ix:opt("name"))
		if guildTags[name] == nil then
			ix:replyEphemeral(`No tag called \`{name}\`.`)
			return
		end
		guildTags[name] = nil
		ctx.store:set("tags", all)
		ix:reply(`Deleted tag \`{name}\`.`)
	end)

	client:command("tag list", function(ix: Discord.Interaction)
		local names = {}
		for name in tagsFor(ix:requireGuildId()) do
			table.insert(names, `\`{name}\``)
		end
		table.sort(names)
		if #names == 0 then
			ix:replyEphemeral("No tags here yet. Make one with `/tag set`.")
			return
		end
		ix:reply({
			embeds = {
				Embed.new()
					:setTitle(`Tags ({#names})`)
					:setDescription(table.concat(names, ", "))
					:setColor(Discord.Color.BLURPLE),
			},
		})
	end)

	----------------------------------------------------------------------
	-- Reminders
	----------------------------------------------------------------------

	client:command("remind", function(ix: Discord.Interaction)
		local minutes: number = ix:opt("minutes")
		local about = Util.truncate(ix:opt("about"), 500)
		local channelId = ix:requireChannelId()
		local userId = ix.user.id

		-- In-memory only: a restart forgets this. Persisting reminders and
		-- rescheduling them on boot is the obvious next step, and is exactly
		-- what `store.luau` is for.
		task.delay(minutes * 60, function()
			pcall(function()
				client:send(channelId, {
					content = `<@{userId}> you asked me to remind you: {Util.escapeMarkdown(about)}`,
					allowed_mentions = Discord.Payload.allowedMentions({ users = true }),
				})
			end)
		end)

		ix:replyEphemeral(
			`I will remind you {Util.timestamp(os.time() + minutes * 60, "R")}. `
				.. "Note this lives in memory -- a restart forgets it."
		)
	end)

	----------------------------------------------------------------------
	-- Webhooks
	----------------------------------------------------------------------

	--[[
		A webhook is how a bot posts under a different name and avatar. They
		are a limited resource (15 per channel) and they persist, so this one
		is created, used, and deleted -- leaking one per invocation would
		fill the channel's quota within an afternoon.
	]]
	client:command("say", function(ix: Discord.Interaction)
		if not Permissions.has(ix:appPermissions(), "manageWebhooks") then
			ix:replyEphemeral("I need **manageWebhooks** in this channel.")
			return
		end
		ix:defer(true)

		local hook = client.api.webhooks.create(
			ix:requireChannelId(),
			{ name = "kitchen-sink-say" },
			`/say by {ix.user.username}`
		)
		-- A webhook created by a bot is an incoming one, which always has a token.
		local token = assert(hook.token, "incoming webhooks carry a token")
		local ok, err = pcall(function()
			client.api.webhooks.execute(hook.id, token, {
				content = ix:opt("message"),
				username = Util.truncate(ix:opt("name", ix.user.username), 80),
				avatar_url = require("@bot/commands/info").avatarUrl(ix.user, 128),
				allowed_mentions = Discord.Payload.NO_MENTIONS,
			})
		end)
		-- Delete it whether or not the send worked.
		pcall(function()
			client.api.webhooks.delete(hook.id, "one-shot webhook")
		end)
		if not ok then
			error(err)
		end
		ix:editReply("Sent.")
	end)

	----------------------------------------------------------------------
	-- File uploads
	----------------------------------------------------------------------

	client:command("upload", function(ix: Discord.Interaction)
		local kind = ix:opt("kind")
		local files: { Discord.File } = {}
		if kind == "roles" then
			local roles = client.api.guilds.getRoles(ix:requireGuildId())
			table.sort(roles, function(a: Discord.Role, b: Discord.Role): boolean
				return a.position > b.position
			end)
			local lines = { "position,id,name,colour,permissions" }
			for _, role in roles do
				-- Quote the name: role names can contain commas.
				table.insert(
					lines,
					`{role.position},{role.id},"{string.gsub(role.name, '"', '""')}",`
						.. `{string.format("#%06X", role.color)},{role.permissions}`
				)
			end
			table.insert(files, { name = "roles.csv", data = table.concat(lines, "\n"), contentType = "text/csv" })
		else
			table.insert(files, {
				name = "README.md",
				data = "# Uploaded from Lute\n\nThis file never touched the disk.\n"
					.. "`net.request` only takes a string body, so the library builds the\n"
					.. "multipart/form-data envelope itself -- see `src/http.luau`.\n",
				contentType = "text/markdown",
			})
		end
		ix:reply({ content = "Here you go:", files = files })
	end)

	client:command("colour", function(ix: Discord.Interaction)
		local hex = string.upper((string.gsub(ix:opt("hex"), "^#", "")))
		if string.match(hex, "^%x%x%x%x%x%x$") == nil then
			ix:replyEphemeral("Give me a six-digit hex colour, like `#5865F2`.")
			return
		end
		local value = tonumber(hex, 16) :: number
		local red = math.floor(value / 65536) % 256
		local green = math.floor(value / 256) % 256
		local blue = value % 256
		-- Relative luminance, so the label stays readable on either ground.
		local luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
		local ink = if luminance > 0.55 then "#000000" else "#FFFFFF"

		local svg = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200">`
			.. `<rect width="400" height="200" fill="#{hex}"/>`
			.. `<text x="200" y="112" font-family="monospace" font-size="34" fill="{ink}" `
			.. `text-anchor="middle">#{hex}</text></svg>`

		ix:reply({
			embeds = {
				Embed.new()
					:setTitle(`#{hex}`)
					:setColor(value)
					:addField("RGB", `{red}, {green}, {blue}`, true)
					:addField("Luminance", string.format("%.2f", luminance), true),
			},
			files = { { name = `colour-{hex}.svg`, data = svg, contentType = "image/svg+xml" } },
		})
	end)

	----------------------------------------------------------------------
	-- Reaction roles
	----------------------------------------------------------------------

	client:command("reactionrole", function(ix: Discord.Interaction)
		if not Permissions.has(ix:appPermissions(), "manageRoles") then
			ix:replyEphemeral("I need **manageRoles** for that.")
			return
		end
		local messageId = ix:opt("message_id")
		if not Snowflake.isValid(messageId) then
			ix:replyEphemeral("That is not a message ID. Turn on Developer Mode, then right-click the message.")
			return
		end
		local role = ix:requireRole("role")
		local emoji = ix:opt("emoji")

		local guild = client.cache:getGuild(ix.guildId)
		local bot = client.user
		local me = if guild ~= nil and bot ~= nil then client.cache:getMember(guild.id, bot.id) else nil
		if guild ~= nil and me ~= nil then
			local roles = client.cache:getRoles(guild.id)
			local asMember = { user = { id = role.id }, roles = { role.id }, joined_at = "" }
			if not Permissions.outranks(guild, me, asMember :: any, roles) then
				ix:replyEphemeral(`**{role.name}** sits at or above my highest role, so I cannot assign it.`)
				return
			end
		end

		-- React first: if the bot cannot add the reaction it cannot see the
		-- message either, and saving a mapping that can never fire is worse
		-- than failing here.
		local ok, err = pcall(function()
			client.api.channels.addReaction(ix:requireChannelId(), messageId, emoji)
		end)
		if not ok then
			ix:replyEphemeral(
				`I could not react to that message: {tostring(err)}\n`
					.. "It has to be in this channel, and the emoji has to be one I can use."
			)
			return
		end

		local all = ctx.store:get("reactionRoles", {})
		all[messageId] = all[messageId] or {}
		-- Custom emoji arrive from the gateway as `name:id`, unicode ones as
		-- the character; key on whichever form this is.
		all[messageId][emoji] = { roleId = role.id, guildId = ix.guildId }
		ctx.store:set("reactionRoles", all)

		ix:replyEphemeral({
			embeds = {
				Embed.new()
					:setTitle("Reaction role armed")
					:setColor(Discord.Color.GREEN)
					:setDescription(`Reacting {emoji} on [that message](https://discord.com/channels/{ix.guildId}/{ix.channelId}/{messageId}) now grants <@&{role.id}>. Removing the reaction takes it away.`)
					:setFooter("stored on disk, so it survives a restart"),
			},
			components = {
				Components.row(
					Components.linkButton(
						"Jump to message",
						`https://discord.com/channels/{ix.guildId}/{ix.channelId}/{messageId}`
					)
				),
			},
		})
	end)
end

return Utility
