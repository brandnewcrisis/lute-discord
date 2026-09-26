--!strict
--[[
	End-to-end smoke test against a real Discord server.

	Exercises the paths a unit test cannot: multipart uploads, reactions,
	edits, webhooks, bulk delete, and the rate limiter under a burst. Every
	message it creates is deleted before it exits, so a clean run leaves the
	channel exactly as it found it.

		lute run tools/smoke.luau <channelId>

	Reads DISCORD_TOKEN from the environment or `.env`. The channel can also
	come from SMOKE_CHANNEL_ID.
]]
local process = require("@lute/process")
local task = require("@lute/task")

local Discord = require("@discord")
local Components = Discord.Components
local Embed = Discord.Embed
local Util = Discord.Util

local env = Discord.Env.load()
local channelId = process.args[2] or env:get("SMOKE_CHANNEL_ID")
if channelId == nil then
	print("usage: lute run tools/smoke.luau <channelId>   (or set SMOKE_CHANNEL_ID)")
	process.exit(1)
end

Discord.Log.setLevel(env:get("LOG_LEVEL", "info") :: string)
local http = Discord.Http.new(env:require("DISCORD_TOKEN"))
local api = Discord.Api.new(http)

-- An 8x8 blurple PNG, so the V2 gallery has a real image to reference.
local SWATCH_PNG = "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A\x00\x00\x00\x0D\x49\x48\x44\x52\x00\x00\x00\x08\x00\x00\x00\x08\x08\x02\x00\x00\x00\x4B\x6D\x29\xDC\x00\x00\x00\x11\x49\x44\x41\x54\x78\x9C\x63\x88\x48\xFD\x84\x15\x31\x0C\x2D\x09\x00\xF3\xAF\x6B\xC1\xFD\x8F\x0B\x4B\x00\x00\x00\x00\x49\x45\x4E\x44\xAE\x42\x60\x82"

local created: { string } = {}
local passed, failed = 0, 0

local function step(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`ok   {name}`)
	else
		failed += 1
		print(`FAIL {name} -- {tostring(err)}`)
	end
end

-- Inside `Discord.main` so a bad token prints Discord's message; Lute's
-- top level prints nothing for a thrown ApiError.
Discord.main(function()
	local me = api.users.getCurrent()
	print(`connected as {me.username} ({me.id})`)
	local channel = api.channels.get(channelId :: string)
	print(`target: #{channel.name} in guild {tostring(channel.guild_id)}\n`)

	local plain: any = nil
	step("send a plain message", function()
		plain = api.channels.createMessage(channelId :: string, "lute-discord smoke test")
		table.insert(created, plain.id)
	end)

	step("edit a message", function()
		api.channels.editMessage(channelId :: string, plain.id, "lute-discord smoke test (edited)")
	end)

	step("add a reaction", function()
		api.channels.addReaction(channelId :: string, plain.id, "\u{2705}")
	end)

	step("read reactions back", function()
		local users = api.channels.getReactions(channelId :: string, plain.id, "\u{2705}")
		assert(#users >= 1, "expected at least one reaction")
	end)

	step("remove own reaction", function()
		api.channels.deleteOwnReaction(channelId :: string, plain.id, "\u{2705}")
	end)

	step("send an embed with components", function()
		local message = api.channels.createMessage(channelId :: string, {
			embeds = {
				Embed.new()
					:setTitle("Embed and components")
					:setDescription("Built with the builders; validated before it left the process.")
					:setColor(Discord.Color.BLURPLE)
					:addField("Inline", "yes", true)
					:addField("Also inline", "yes", true)
					:setFooter("smoke test")
					:setTimestamp(),
			},
			components = {
				Components.row(
					Components.button({ id = "smoke:a", label = "Primary", style = "primary" }),
					Components.button({ id = "smoke:b", label = "Danger", style = "danger", emoji = "\u{1f525}" }),
					Components.linkButton("Lute", "https://github.com/luau-lang/lute")
				),
				Components.row(Components.select({
					id = "smoke:pick",
					placeholder = "A select menu",
					options = { { label = "One", value = "1" }, { label = "Two", value = "2" } },
				})),
			},
		})
		table.insert(created, message.id)
	end)

	step("send a Components V2 message with an attachment:// file", function()
		local message = api.channels.createMessage(channelId :: string, {
			components = {
				Components.container(
					{ accent = "#5865F2", spoiler = false },
					Components.section(
						{ accessory = Components.button({ id = "smoke:v2", label = "Section button" }) },
						"## Components V2",
						"A container, a section with an accessory, a separator, a gallery and a file."
					),
					Components.separator({ divider = true, spacing = "large" }),
					Components.gallery(
						{ url = "attachment://swatch.png", description = "an uploaded image, referenced by name" }
					),
					Components.file("attachment://notes.txt")
				),
			},
			files = {
				{ name = "swatch.png", data = SWATCH_PNG, contentType = "image/png" },
				{ name = "notes.txt", data = "Referenced from a File component.\n", contentType = "text/plain" },
			},
		})
		assert(
			bit32.band(message.flags or 0, Discord.Const.MessageFlag.IS_COMPONENTS_V2) ~= 0,
			"the V2 flag should have been set automatically"
		)
		table.insert(created, message.id)
	end)

	step("edit a message through a webhook, then read it back", function()
		local hook = api.webhooks.create(channelId :: string, { name = "lute-smoke-edit" }, "smoke test")
		local token = assert(hook.token, "a freshly created webhook has a token")
		local sent = assert(api.webhooks.execute(hook.id, token, { content = "before" }, { wait = true }))
		api.webhooks.editMessage(hook.id, token, sent.id, { content = "after" })
		local fetched = api.webhooks.getMessage(hook.id, token, sent.id)
		assert(fetched.content == "after", `expected edited content, got {tostring(fetched.content)}`)
		table.insert(created, sent.id)
		api.webhooks.deleteWithToken(hook.id, token)
	end)

	step("upload two files in one message", function()
		local message = api.channels.createMessage(channelId :: string, {
			content = "Multipart upload, assembled by hand because `net.request` takes a string body.",
			files = {
				{ name = "notes.md", data = "# Uploaded from Lute\n\nNever touched the disk.\n", contentType = "text/markdown" },
				{
					name = "swatch.svg",
					data = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">'
						.. '<rect width="200" height="100" fill="#5865F2"/></svg>',
					contentType = "image/svg+xml",
				},
			},
		})
		assert(#message.attachments == 2, `expected 2 attachments, got {#message.attachments}`)
		table.insert(created, message.id)
	end)

	step("create, use and delete a webhook", function()
		local hook = api.webhooks.create(channelId :: string, { name = "lute-smoke" }, "smoke test")
		-- Only incoming webhooks carry a token, and `create` always makes one.
		local token = assert(hook.token, "a freshly created webhook has a token")
		local sent = api.webhooks.execute(hook.id, token, {
			content = "Sent through a webhook, under a different name.",
			username = "Kitchen Sink",
		}, { wait = true })
		if sent ~= nil then
			table.insert(created, sent.id)
		end
		api.webhooks.delete(hook.id, "smoke test cleanup")
	end)

	--[[
		The rate limiter under load.

		Twenty messages to one channel is well past the per-channel burst
		allowance, so this either completes smoothly -- meaning the limiter
		predicted the window -- or it 429s, which the log will say.
	]]
	step("burst 20 messages through one bucket", function()
		local before = Util.now()
		local ids: { string } = {}
		local pending = 0
		for index = 1, 20 do
			pending += 1
			task.spawn(function()
				local message = api.channels.createMessage(channelId :: string, `burst {index}/20`)
				table.insert(ids, message.id)
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait(0.05)
		end
		print(
			`     20 messages in {string.format("%.1f", Util.since(before))}s, `
				.. `{http.rateLimitHits} rate limit hit(s), {http.requestCount} requests total`
		)
		for _, id in ids do
			table.insert(created, id)
		end
		assert(#ids == 20, `expected 20 messages, got {#ids}`)
	end)

	step("bulk delete everything created", function()
		-- Bulk delete takes 2 to 100; anything less falls back to single deletes.
		while #created > 1 do
			local batch = {}
			for _ = 1, math.min(100, #created) do
				table.insert(batch, table.remove(created) :: string)
			end
			if #batch >= 2 then
				api.channels.bulkDeleteMessages(channelId :: string, batch, "smoke test cleanup")
			else
				api.channels.deleteMessage(channelId :: string, batch[1], "smoke test cleanup")
			end
		end
		if #created == 1 then
			api.channels.deleteMessage(channelId :: string, created[1], "smoke test cleanup")
			table.remove(created)
		end
	end)
end)

print(`\n{passed} passed, {failed} failed`)
if #created > 0 then
	print(`WARNING: {#created} message(s) were left behind`)
end
if failed > 0 then
	process.exit(1)
end
