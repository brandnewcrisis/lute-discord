--!strict
--[[
	The interactive surface: /buttons, /menu, /feedback, /card, /paginate,
	/confirm, /timer.

	Each one demonstrates a different way of waiting for the user:

	  /buttons   a collector scoped to one message and one person
	  /menu      select menus, including the ones Discord populates itself
	  /feedback  a modal, which must be the FIRST response to an interaction
	  /card      a Components V2 message: layout with no embed at all
	  /paginate  the built-in paginator
	  /confirm   `collector:await()`, so a yes/no flow reads top to bottom
	  /timer     defer plus repeated edits, for work longer than 3 seconds
]]
local task = require("@lute/task")

local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components
local Embed = Discord.Embed
local Paginator = Discord.Paginator
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Ui = {}

Ui.commands = {
	Commands.slash("buttons", "Every button style, and a counter that remembers"),
	Commands.slash("menu", "Select menus, including Discord-populated ones"),
	Commands.slash("feedback", "Open a form"),
	Commands.slash("card", "A Components V2 layout: container, section, gallery"),
	Commands.slash("paginate", "A paginated list")
		:integerOption("items", "How many items to page through", { min = 1, max = 500 }),
	Commands.slash("confirm", "A yes/no prompt written as straight-line code"),
	Commands.slash("timer", "Work that takes longer than Discord's 3 second window")
		:integerOption("seconds", "How long to pretend to work", { min = 1, max = 30 }),
}

function Ui.register(client: Discord.Client, _ctx: Ctx.Ctx)
	client:command("buttons", function(ix: Discord.Interaction)
		local count = 0

		local function render(disabled: boolean): any
			return {
				embeds = {
					Embed.new()
						:setTitle("Buttons")
						:setDescription(
							`Pressed **{count}** time(s).\n\n`
								.. "The counter lives in this handler's closure, and the collector below "
								.. "only accepts presses from you, on this message, for 60 seconds."
						)
						:setColor(if disabled then Discord.Color.GREY else Discord.Color.BLURPLE),
				},
				components = {
					Components.row(
						Components.button({ id = "demo:press", label = "Press me", style = "success", emoji = "\u{2728}", disabled = disabled }),
						Components.button({ id = "demo:reset", label = "Reset", style = "danger", disabled = disabled }),
						Components.button({ id = "demo:noop", label = "Secondary", style = "secondary", disabled = disabled }),
						Components.linkButton("Lute", "https://github.com/luau-lang/lute")
					),
				},
			}
		end

		ix:reply(render(false))
		local message = ix:fetchReply()

		client:collect({
			messageId = message.id,
			userId = ix.user.id,
			timeout = 60,
			onCollect = function(event: any)
				if event.data.custom_id == "demo:reset" then
					count = 0
				elseif event.data.custom_id == "demo:press" then
					count += 1
				end
				event:update(render(false))
			end,
			onEnd = function()
				-- Expired buttons that still look clickable read as a broken
				-- bot, so grey them out.
				pcall(function()
					ix:editReply(render(true))
				end)
			end,
		})
	end)

	client:command("menu", function(ix: Discord.Interaction)
		ix:reply({
			content = "Pick something. The user menu is populated by Discord itself -- "
				.. "the chosen member arrives fully resolved, with no extra request.",
			components = {
				Components.row(Components.select({
					id = "demo:flavour",
					placeholder = "Choose up to two flavours",
					min = 1,
					max = 2,
					options = {
						{ label = "Vanilla", value = "vanilla", description = "The default", emoji = "\u{1f366}" },
						{ label = "Chocolate", value = "chocolate", emoji = "\u{1f36b}" },
						{ label = "Strawberry", value = "strawberry", emoji = "\u{1f353}" },
					},
				})),
				Components.row(Components.userSelect({ id = "demo:user", placeholder = "Pick a member" })),
				Components.row(Components.channelSelect({
					id = "demo:channel",
					placeholder = "Pick a text channel",
					channelTypes = { Discord.ChannelType.GUILD_TEXT },
				})),
			},
			ephemeral = true,
		})
	end)

	client:component("demo:flavour", function(ix: Discord.Interaction)
		ix:update({
			content = `You chose: **{table.concat(ix:values(), "**, **")}**`,
			components = {},
		})
	end)

	client:component("demo:user", function(ix: Discord.Interaction)
		local id = ix:values()[1]
		local users: any = ix.data.resolved ~= nil and ix.data.resolved.users or nil
		local resolved: any = if users ~= nil then users[id] else nil
		ix:update({
			content = `You picked <@{id}>`
				.. (if resolved then ` -- resolved without a fetch: \`{resolved.username}\`` else ""),
			components = {},
		})
	end)

	client:component("demo:channel", function(ix: Discord.Interaction)
		ix:update({ content = `You picked <#{ix:values()[1]}>`, components = {} })
	end)

	client:command("feedback", function(ix: Discord.Interaction)
		-- Note there is no defer: a modal has to be the first response.
		-- Each field sits in a Label, which carries its title and hint. The
		-- older shape -- a bare text input with its own label -- still works,
		-- but only text inputs can go in a modal that way.
		ix:showModal(Components.modal({
			id = "feedback",
			title = "Send feedback",
			components = {
				Components.label(
					"What is it about?",
					Components.radioGroup({
						id = "kind",
						required = true,
						options = {
							{ label = "A bug", value = "bug" },
							{ label = "An idea", value = "idea", default = true },
							{ label = "Something else", value = "other" },
						},
					})
				),
				Components.label("Subject", Components.textInput({ id = "subject", max = 80, required = true })),
				Components.label(
					"What happened?",
					Components.textInput({
						id = "body",
						style = "paragraph",
						placeholder = "As much detail as you like",
						max = 1000,
						required = true,
					})
				),
				Components.label(
					"Screenshots",
					Components.fileUpload({ id = "shots", max = 3, required = false }),
					"Optional, up to three"
				),
				Components.label("Follow up with me", Components.checkbox({ id = "contact" })),
			},
		}))
	end)

	client:modal("feedback", function(ix: Discord.Interaction)
		local kind = ix:modalValue("kind") or "other"
		local shots = ix:modalFiles("shots")
		local embed = Embed.new()
			:setTitle("Thanks -- here is what I received")
			:setColor(Discord.Color.GREEN)
			:addField("Kind", kind, true)
			:addField("Follow up", if ix:modalChecked("contact") then "yes" else "no", true)
			:addField("Screenshots", tostring(#shots), true)
			:addField("Subject", Util.escapeMarkdown(ix:modalValue("subject") or ""), false)
			:addTrimmedField("Body", Util.escapeMarkdown(ix:modalValue("body") or ""), false)
			:setFooter("a real bot would file this somewhere")
		if #shots > 0 then
			embed:setImage(shots[1].url)
		end
		ix:replyEphemeral({ embeds = { embed } })
	end)

	--[[
		Components V2: the message IS the layout. No content, no embed --
		text, media and buttons are all components, and a container gives
		the boxed look an embed used to. Setting `v2 = true` (or using any
		V2-only component, which sets it for you) is permanent for the
		message, so every later edit has to be V2 as well.
	]]
	client:command("card", function(ix: Discord.Interaction)
		local user = ix.user
		local avatar = Discord.Api.cdn.userAvatar(user, { size = 256 })
		ix:reply({
			v2 = true,
			components = {
				Components.container(
					{ accent = Discord.Color.BLURPLE },
					Components.section(
						{ accessory = Components.thumbnail(avatar, { description = "your avatar" }) },
						`## {Util.escapeMarkdown(user.global_name or user.username)}`,
						`Joined Discord {Util.timestamp(Discord.Snowflake.timestamp(user.id), "R")}`
					),
					Components.separator({ divider = true, spacing = "small" }),
					"Sections pair text with a thumbnail or a button. Galleries hold up to ten images:",
					Components.gallery(avatar, Discord.Api.cdn.defaultAvatar(user)),
					Components.row(
						Components.button({ id = "card:wave", label = "Wave", emoji = "\u{1f44b}" }),
						Components.linkButton("Components docs", "https://discord.com/developers/docs/components/overview")
					)
				),
			},
		})
	end)

	client:component("card:wave", function(ix: Discord.Interaction)
		ix:replyEphemeral(`{ix.user.username} waved.`)
	end)

	client:command("paginate", function(ix: Discord.Interaction)
		local count = ix:opt("items", 40)
		local lines = {}
		for index = 1, count do
			table.insert(lines, `\`{string.format("%03d", index)}\` item number {index}`)
		end
		local pages: { Discord.PaginatorPage } = {}
		for index, chunk in Paginator.chunk(lines, 10) do
			local page = Embed.new():setTitle(`Items, page {index}`):setDescription(chunk):setColor(Discord.Color.BLURPLE)
			table.insert(pages, page)
		end
		Paginator.reply(client, ix, { pages = pages, timeout = 120 })
	end)

	client:command("confirm", function(ix: Discord.Interaction)
		ix:reply({
			content = "Delete every one of your imaginary files?",
			components = {
				Components.row(
					Components.button({ id = "confirm:yes", label = "Do it", style = "danger" }),
					Components.button({ id = "confirm:no", label = "Cancel", style = "secondary" })
				),
			},
			ephemeral = true,
		})

		-- `await` turns the callback dance into three readable lines. The
		-- handler is already on its own task, so blocking here blocks
		-- nothing else.
		local collector = client:collect({ userId = ix.user.id, timeout = 30, max = 1 })
		local answer = collector:await()

		if answer == nil then
			ix:editReply({ content = "Timed out -- nothing was deleted.", components = {} })
		elseif answer.data.custom_id == "confirm:yes" then
			answer:update({ content = "Deleted zero imaginary files.", components = {} })
		else
			answer:update({ content = "Cancelled.", components = {} })
		end
	end)

	client:command("timer", function(ix: Discord.Interaction)
		local seconds = ix:opt("seconds", 8)
		-- Past three seconds the token dies, so defer first and edit after.
		ix:defer()
		for elapsed = 1, seconds do
			task.wait(1)
			if elapsed % 2 == 0 or elapsed == seconds then
				local filled = math.floor(elapsed / seconds * 20 + 0.5)
				ix:editReply({
					content = `Working... \`{string.rep("\u{2588}", filled)}{string.rep("\u{2591}", 20 - filled)}\` {elapsed}/{seconds}s`,
				})
			end
		end
		ix:editReply({ content = `Done in {seconds}s. Deferring buys fifteen minutes; the raw window is three seconds.` })
	end)
end

return Ui
