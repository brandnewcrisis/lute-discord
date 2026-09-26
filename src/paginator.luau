--!strict
--[[
	A paginated message: page N of M, with navigation buttons.

	Built on collectors rather than a global component handler, because the
	buttons belong to one message and one person. Two properties matter and
	are easy to miss when hand-rolling this:

	  * Navigation must `update` the existing message, not reply. Replying
	    leaves a trail of pages in the channel.
	  * When the collector expires the buttons must be disabled. Otherwise
	    they stay clickable forever and do nothing, which reads as a broken
	    bot rather than an expired one.
]]
local blame = require("@discord/blame")
local Client = require("@discord/client")
local Collector = require("@discord/collector")
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Interaction = require("@discord/interaction")
local Payload = require("@discord/payload")
local Spec = require("@discord/spec")
local Types = require("@discord/types")

local Paginator = {}

--[[
	One page.

	A string is the message content, an embed (or an embed builder) becomes
	the whole message, and anything else is taken as a full message payload
	with the navigation row merged into it. See `pagePayload` for how an
	embed is told apart.

	`Embed.Embed` is listed even though `Buildable<Types.Embed>` already
	admits it structurally. Structural is not enough at a generic call:
	`table.insert(pages, Embed.new():setTitle("x"))` makes Luau infer
	`table.insert`'s element type from BOTH arguments, and matching the
	builder's `toJSON(self: Embed)` against `toJSON: (any) -> Embed` fails
	there even though assigning the same value to a local first succeeds.
	Naming the builder type makes the match exact.
]]
export type Page = Types.MessageInput | Embed.Embed | Types.Buildable<Types.Embed>

export type Options = {
	--- One payload per page: an embed, a string, or a full message payload.
	pages: { Page },
	--- Only this user may navigate. Defaults to whoever opened it.
	userId: string?,
	timeout: number?,
	--- Show the page counter in the button row. Default true.
	counter: boolean?,
	ephemeral: boolean?,
}

local OPTION_KEYS = Spec.keys({ "pages", "userId", "timeout", "counter", "ephemeral" })
local OPTION_ALIASES = { user = "userId", time = "timeout", embeds = "pages" }

-- Keys only an embed has, and keys only a message has. A page is a plain
-- embed when it has any of the first and none of the second: an embed can
-- be nothing but `fields`, or nothing but an `image`.
local EMBED_KEYS =
	{ "title", "description", "fields", "image", "thumbnail", "author", "footer", "color", "url", "timestamp" }
local MESSAGE_KEYS = { "content", "embeds", "embed", "components", "files" }

local function hasAny(node: { [string]: any }, keys: { string }): boolean
	for _, key in keys do
		if node[key] ~= nil then
			return true
		end
	end
	return false
end

local function pagePayload(page: Page): Types.MessagePayload
	if type(page) == "string" then
		return { content = page }
	end
	-- Telling an embed from a message payload is a runtime question -- the
	-- two are both tables and only their fields distinguish them -- so this
	-- is where the union gets discriminated by hand. A builder is known by
	-- its `toJSON` (usually reached through its metatable); a message
	-- payload never has one.
	local node = page :: { [string]: any }
	if type(node.toJSON) == "function" or (hasAny(node, EMBED_KEYS) and not hasAny(node, MESSAGE_KEYS)) then
		return { embeds = { page :: Types.Buildable<Types.Embed> } }
	end
	return page :: Types.MessagePayload
end

local function buttons(id: string, index: number, total: number, counter: boolean, dead: boolean): { Types.ActionRow }
	local row: { Types.Component } = {
		Components.button({
			id = `{id}:first`,
			emoji = "\u{23ee}\u{fe0f}",
			style = "secondary",
			disabled = dead or index == 1,
		}),
		Components.button({
			id = `{id}:prev`,
			emoji = "\u{25c0}\u{fe0f}",
			style = "primary",
			disabled = dead or index == 1,
		}),
	}
	if counter then
		-- A disabled button is the only way to show a static label inline
		-- with the controls; Discord has no text component in an action row.
		table.insert(
			row,
			Components.button({ id = `{id}:page`, label = `{index} / {total}`, style = "secondary", disabled = true })
		)
	end
	table.insert(
		row,
		Components.button({
			id = `{id}:next`,
			emoji = "\u{25b6}\u{fe0f}",
			style = "primary",
			disabled = dead or index == total,
		})
	)
	table.insert(
		row,
		Components.button({
			id = `{id}:last`,
			emoji = "\u{23ed}\u{fe0f}",
			style = "secondary",
			disabled = dead or index == total,
		})
	)
	return { Components.row(table.unpack(row)) }
end

--[[
	Sends the paginated message in reply to an interaction and wires up
	navigation. Returns once the first page is on screen; navigation
	continues on the collector's own tasks.
]]
function Paginator.reply(client: Client.Client, ix: Interaction.Interaction, options: Options): Collector.Collector?
	Spec.check(options, OPTION_KEYS, "paginator", OPTION_ALIASES)
	local pages = options.pages
	if pages == nil or #pages == 0 then
		error("a paginator needs at least one page", blame())
	end

	local index = 1
	local total = #pages
	local counter = options.counter ~= false
	-- Scoped to this interaction so two paginators in a channel cannot
	-- collide, even for the same user.
	local id = `page:{ix.id}`

	--[[
		Every page must be the same kind of message. IS_COMPONENTS_V2 can
		be set on an edit but never cleared, so paging from a V2 page to a
		legacy one would fail on Discord's side mid-navigation, long after
		the paginator was built. Checked up front instead.
	]]
	local firstV2: boolean? = nil
	for number, page in pages do
		local payload = pagePayload(page)
		local isV2 = payload.v2 == true
			or bit32.btest(payload.flags or 0, Const.MessageFlag.IS_COMPONENTS_V2)
			or Components.isV2(payload.components or {})
		if firstV2 == nil then
			firstV2 = isV2
		elseif isV2 ~= firstV2 then
			error(`paginator page {number} is {if isV2 then "" else "not "}Components V2 but page 1 is {if firstV2 then "" else "not "}; Discord cannot switch a message back`, blame())
		end
	end

	local function render(dead: boolean): Types.MessagePayload
		local out = Payload.copy(pagePayload(pages[index]))
		-- The navigation row is appended to whatever the page already has,
		-- so a page can carry its own buttons or, under V2, its whole layout.
		local own = out.components
		local merged: { Types.Component } = if type(own) == "table" then table.clone(own) else {}
		if total > 1 or dead then
			for _, row in buttons(id, index, total, counter, dead) do
				table.insert(merged, row)
			end
		end
		out.components = if #merged > 0 then merged else nil
		if options.ephemeral then
			out.ephemeral = true
		end
		return out
	end

	--[[
		The message the buttons live on. `reply` returns it except for a
		first response, which Discord does not echo back; only then is
		`@original` fetched. When the interaction was already answered the
		page went out as a follow-up, and `@original` is some OTHER message
		-- collecting on it would match no clicks, and editing it on expiry
		would overwrite the wrong message.
	]]
	local sent, followUp = Interaction.reply(ix, render(false))
	if total == 1 then
		-- One page needs no navigation, so there is no collector to hand back.
		return nil
	end

	local message: Types.Message? = sent
	if message == nil then
		local ok, fetched = pcall(Interaction.fetchReply, ix)
		if ok then
			message = fetched
		end
	end

	return client:collect({
		messageId = if message ~= nil then message.id else nil,
		userId = options.userId or ix.user.id,
		timeout = options.timeout or 180,
		filter = function(event: Interaction.Interaction): boolean
			return string.sub(event.data.custom_id or "", 1, #id) == id
		end,
		onCollect = function(event: Interaction.Interaction)
			local action = string.match(event.data.custom_id or "", ":(%a+)$")
			if action == "first" then
				index = 1
			elseif action == "prev" then
				index = math.max(1, index - 1)
			elseif action == "next" then
				index = math.min(total, index + 1)
			elseif action == "last" then
				index = total
			end
			Interaction.update(event, render(false))
		end,
		onEnd = function()
			-- Expired: leave the last page up, but stop pretending the
			-- buttons work.
			pcall(function()
				if followUp and message ~= nil then
					ix.client.api.interactions.editFollowup(ix.applicationId, ix.token, message.id, render(true))
				else
					Interaction.editReply(ix, render(true))
				end
			end)
		end,
	})
end

--- Splits a long list into pages of `perPage` lines, ready for `pages`.
function Paginator.chunk(lines: { string }, perPage: number): { string }
	local pages = {}
	for start = 1, math.max(#lines, 1), perPage do
		local slice = table.move(lines, start, math.min(start + perPage - 1, #lines), 1, {})
		table.insert(pages, table.concat(slice, "\n"))
	end
	return pages
end

return Paginator
