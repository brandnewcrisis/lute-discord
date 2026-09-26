--!strict
--[[
	Core commands: /ping, /help, /stats, /shutdown.

	`/ping` is the one that shows the two latencies that actually matter and
	are usually conflated: the gateway heartbeat round trip (how far you are
	from Discord's socket) and a REST round trip (how loaded the API is).
]]
local process = require("@lute/process")

local Discord = require("@discord")
local Commands = Discord.Commands
local Embed = Discord.Embed
local Paginator = Discord.Paginator
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Core = {}

Core.commands = {
	Commands.slash("ping", "Round-trip latency to Discord"),
	Commands.slash("help", "Everything this bot can do"),
	Commands.slash("stats", "Uptime, memory, cache and API counters"),
	Commands.slash("shutdown", "Stop the bot (owner only)"):defaultPermissions("administrator"):guildOnly(),
}

function Core.register(client: Discord.Client, ctx: Ctx.Ctx)
	client:command("ping", function(ix: Discord.Interaction)
		local before = Util.now()
		-- A cheap authenticated call, purely to time the REST path.
		client.api.users.getCurrent()
		local rest = Util.since(before)

		ix:reply({
			embeds = {
				Embed.new()
					:setTitle("Pong")
					:setColor(Discord.Color.GREEN)
					:addField("Gateway", `{math.floor(client:latency() * 1000)} ms`, true)
					:addField("REST", `{math.floor(rest * 1000)} ms`, true)
					:setFooter(`shard {#client.shards} of {#client.shards}`),
			},
		})
	end)

	client:command("help", function(ix: Discord.Interaction)
		-- One page per five commands, driven by the same list that was
		-- deployed, so help can never drift from what actually exists.
		local lines = {}
		for _, command in ctx.commands do
			local data = command:toJSON()
			if data.description ~= nil then
				table.insert(lines, `**/{data.name}** - {data.description}`)
			else
				table.insert(lines, `**{data.name}** - right-click menu`)
			end
		end
		table.sort(lines)

		local pages: { Discord.PaginatorPage } = {}
		for _, chunk in Paginator.chunk(lines, 8) do
			local page = Embed.new()
				:setTitle("Commands")
				:setDescription(chunk)
				:setColor(Discord.Color.BLURPLE)
				:setFooter("lute-discord kitchen sink")
			table.insert(pages, page)
		end
		Paginator.reply(client, ix, { pages = pages, ephemeral = true })
	end)

	client:command("stats", function(ix: Discord.Interaction)
		local cache = client.cache:stats()
		local http = client.http
		ix:reply({
			embeds = {
				Embed.new()
					:setTitle("Runtime")
					:setColor(Discord.Color.BLURPLE)
					:addField("Uptime", Util.duration(client:uptime()), true)
					-- Luau's `gcinfo()` reports the heap in KiB; Lute has no
					-- `collectgarbage`.
					:addField("Memory", `{math.floor(gcinfo() / 102.4) / 10} MiB`, true)
					:addField("Latency", `{math.floor(client:latency() * 1000)} ms`, true)
					:addField("Guilds", tostring(cache.guilds), true)
					:addField("Channels", tostring(cache.channels), true)
					:addField("Cached members", tostring(cache.members), true)
					:addField("REST calls", tostring(http.requestCount), true)
					:addField("429s", tostring(http.rateLimitHits), true)
					:addField("Buckets learned", tostring((function(): number
						local total = 0
						for _ in http.routeToBucket do
							total += 1
						end
						return total
					end)()), true)
					:setFooter(`lute-discord {Discord.VERSION} on {process.execPath():match("[^/]+$") or "lute"}`)
					:setTimestamp(),
			},
		})
	end)

	client:command("shutdown", function(ix: Discord.Interaction)
		local guild = client.cache:getGuild(ix.guildId)
		if guild == nil or ix.user.id ~= guild.owner_id then
			ix:replyEphemeral("Only the server owner can stop the bot.")
			return
		end
		ix:reply("Shutting down. See you.")
		client:stop()
	end)
end

return Core
