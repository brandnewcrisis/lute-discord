--!strict
-- Payload edge cases found in review: edits and forwards that are not
-- "empty", `Json.null` components, V2 edits that do not resend their
-- layout, attachment references on edits, edit-time component limits,
-- character (not byte) counts, select defaults against `min`, ephemeral
-- replies after a public defer, and the paginator's follow-up path.
local Api = require("@discord/api")
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Fakes = require("./fakes")
local Interaction = require("@discord/interaction")
local Json = require("@discord/json")
local Paginator = require("@discord/paginator")
local Payload = require("@discord/payload")
local h = require("./harness")

local V2 = Const.MessageFlag.IS_COMPONENTS_V2
local EPHEMERAL = Const.MessageFlag.EPHEMERAL

local EDIT: Payload.MessageOptions = { edit = true }

local function accepts(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	h.check(name .. (if ok then "" else ` -- {tostring(err)}`), ok)
end

local function sixRows(): { any }
	local rows = {}
	for index = 1, 6 do
		table.insert(rows, Components.row(Components.button({ id = `r{index}`, label = "x" })))
	end
	return rows
end

----------------------------------------------------------------------------
-- 1. Edits and forwards are not "empty"
----------------------------------------------------------------------------

accepts("edit: components = {} strips buttons", function()
	Payload.message({ components = {} }, EDIT)
end)
accepts("edit: embeds = {}", function()
	Payload.message({ embeds = {} }, EDIT)
end)
accepts("edit: embeds = Json.null", function()
	Payload.message({ embeds = Json.null }, EDIT)
end)
accepts("edit: content = Json.null", function()
	Payload.message({ content = Json.null }, EDIT)
end)
accepts("edit: flags alone", function()
	Payload.message({ flags = 4 }, EDIT)
end)
accepts("edit: allowed_mentions alone", function()
	Payload.message({ allowed_mentions = Payload.NO_MENTIONS }, EDIT)
end)
accepts("create: a forward carries no content of its own", function()
	Payload.message({ message_reference = { type = 1, message_id = "1", channel_id = "2" } })
end)
accepts("create: stickers alone", function()
	Payload.message({ sticker_ids = { "5" } })
end)
accepts("create: files alone", function()
	Payload.message({ files = { { name = "a.txt", data = "x" } } })
end)
h.throws("create: a plain reply reference is not content", "payload is empty", function()
	Payload.message({ message_reference = { message_id = "1" } })
end)
h.throws("create: an empty sticker list is not content", "payload is empty", function()
	Payload.message({ sticker_ids = {} })
end)
h.throws("create: components = {} is still empty", "payload is empty", function()
	Payload.message({ components = {} })
end)

-- The edit routes pass the mode: driven through the real endpoint layer.
do
	local http, rest = Fakes.http()
	rest:on("PATCH", ".*", { status = 200, body = { id = "m" } })
	local api = Api.new(http)
	accepts("channels.editMessage strips components", function()
		api.channels.editMessage("c", "m", { components = {} })
	end)
	accepts("interactions.editOriginalResponse clears embeds", function()
		api.interactions.editOriginalResponse("app", "tok", { embeds = {} })
	end)
	accepts("interactions.editFollowup sets flags only", function()
		api.interactions.editFollowup("app", "tok", "m", { flags = 4 })
	end)
	accepts("webhooks.editMessage clears content", function()
		api.webhooks.editMessage("w", "tok", "m", { content = Json.null })
	end)
	h.throws("channels.createMessage still refuses an empty payload", "payload is empty", function()
		api.channels.createMessage("c", { components = {} })
	end)
end

----------------------------------------------------------------------------
-- 2. components = Json.null
----------------------------------------------------------------------------

h.check("isV2 treats a non-table as no components", not Components.isV2(Json.null))
h.check("edit: components = Json.null passes through untouched", (function()
	local ok, body = pcall(function(): any
		return Payload.message({ components = Json.null }, EDIT)
	end)
	return ok and body.components == Json.null
end)())
accepts("create: components = Json.null beside content", function()
	Payload.message({ content = "x", components = Json.null })
end)
h.throws("create: components = Json.null alone is empty", "payload is empty", function()
	Payload.message({ components = Json.null })
end)

----------------------------------------------------------------------------
-- 3. V2 edits need not resend components
----------------------------------------------------------------------------

accepts("edit: V2 flags without components", function()
	Payload.message({ flags = bit32.bor(V2, 4) }, EDIT)
end)
accepts("edit: V2 message, attachments only", function()
	Payload.message({ flags = V2, attachments = { { id = "1" } } }, EDIT)
end)
accepts("edit: v2 = true, allowed_mentions only", function()
	Payload.message({ v2 = true, allowed_mentions = Payload.NO_MENTIONS }, EDIT)
end)
h.throws("edit: explicitly emptying a V2 message is refused", "at least one", function()
	Payload.message({ flags = V2, components = {} }, EDIT)
end)
h.throws("create: a V2 message still needs components", "at least one", function()
	Payload.message({ v2 = true })
end)

----------------------------------------------------------------------------
-- 4. attachment:// against attachments already on the message
----------------------------------------------------------------------------

accepts("edit: a kept attachment named in attachments may be referenced", function()
	Payload.message({
		components = { Components.file("attachment://old.pdf"), Components.gallery("attachment://new.png") },
		files = { { name = "new.png", data = "png" } },
		attachments = { { id = "111", filename = "old.pdf" }, { id = 0, filename = "new.png" } },
	}, EDIT)
end)
accepts("create: attachments filenames count as names", function()
	Payload.message({
		components = { Components.file("attachment://renamed.pdf") },
		files = { { name = "upload.pdf", data = "x" } },
		attachments = { { id = 0, filename = "renamed.pdf" } },
	})
end)
accepts("edit: id-only attachments leave the check to Discord", function()
	Payload.message({
		components = { Components.file("attachment://old.pdf") },
		files = { { name = "new.png", data = "png" } },
		attachments = { { id = "111" } },
	}, EDIT)
end)
accepts("edit: no attachments array keeps existing files, so no check", function()
	Payload.message({
		components = { Components.file("attachment://old.pdf") },
		files = { { name = "new.png", data = "png" } },
	}, EDIT)
end)
h.throws("edit: a full attachments list still catches a dangling reference", "attachment://gone.pdf", function()
	Payload.message({
		components = { Components.file("attachment://gone.pdf") },
		attachments = { { id = "111", filename = "old.pdf" } },
	}, EDIT)
end)

----------------------------------------------------------------------------
-- 5. Edit-time component limits
----------------------------------------------------------------------------

accepts("edit: six rows without a flag (the target may be V2)", function()
	Payload.message({ components = sixRows() }, EDIT)
end)
h.check("edit: the lenient check does not set the flag", (function()
	local ok, body = pcall(function(): any
		return Payload.message({ components = sixRows() }, EDIT)
	end)
	return ok and body.flags == nil
end)())
h.throws("edit: v2 = false keeps legacy limits", "at most 5 action rows", function()
	Payload.message({ v2 = false, components = sixRows() }, EDIT)
end)
h.throws("create: six rows are still refused", "at most 5 action rows", function()
	Payload.message({ components = sixRows() })
end)
h.throws("edit: the V2 ceiling still applies", "at most 40 components", function()
	local tree = {}
	for index = 1, 41 do
		table.insert(tree, Components.row(Components.button({ id = `b{index}`, label = "x" })))
	end
	Payload.message({ components = tree }, EDIT)
end)

----------------------------------------------------------------------------
-- 6. custom_id counts characters
----------------------------------------------------------------------------

accepts("custom_id of 60 two-byte characters", function()
	Components.button({ id = string.rep("é", 60), label = "x" })
end)
accepts("select custom_id of 100 two-byte characters", function()
	Components.userSelect({ id = string.rep("é", 100) })
end)
h.throws("custom_id of 101 characters", "custom_id is 101 characters", function()
	Components.button({ id = string.rep("é", 101), label = "x" })
end)

----------------------------------------------------------------------------
-- 7. Select defaults against min
----------------------------------------------------------------------------

h.throws("defaults below min", "at least 2", function()
	Components.userSelect({ id = "u", min = 2, max = 3, defaults = { "1" } })
end)
accepts("defaults at min", function()
	Components.userSelect({ id = "u", min = 2, max = 3, defaults = { "1", "2" } })
end)
accepts("one default meets the implicit min of 1", function()
	Components.roleSelect({ id = "r", defaults = { "1" } })
end)
accepts("an empty defaults list is no defaults", function()
	Components.userSelect({ id = "u", min = 2, max = 3, defaults = {} })
end)

----------------------------------------------------------------------------
-- Message-wide embed limits
----------------------------------------------------------------------------

h.throws("two 4000-character embeds break the shared budget", "embeds total 8000 characters", function()
	Payload.message({
		embeds = {
			Embed.new():setDescription(string.rep("a", 4000)),
			{ description = string.rep("b", 4000) },
		} :: { any },
	})
end)
h.throws("the shared budget counts characters, fields and footers", "embeds total 6001 characters", function()
	Payload.message({
		embeds = {
			{ title = string.rep("é", 1000), footer = { text = string.rep("f", 2000) } },
			{ fields = { { name = string.rep("n", 1), value = string.rep("v", 1000) } }, author = { name = string.rep("a", 2000) } },
		} :: { any },
	})
end)
accepts("exactly 6000 across embeds passes", function()
	local list: { any } = { { description = string.rep("a", 3000) }, { description = string.rep("b", 3000) } }
	Payload.message({ embeds = list })
end)
h.throws("eleven embeds are refused", "at most 10 embeds, got 11", function()
	local list: { any } = {}
	for index = 1, 11 do
		table.insert(list, { title = `e{index}` })
	end
	Payload.message({ embeds = list })
end)
h.throws("edits are held to the same limits", "embeds total", function()
	local list: { any } = { { description = string.rep("a", 4000) }, { description = string.rep("b", 4000) } }
	Payload.message({ embeds = list }, EDIT)
end)
h.equals("Embed.measure agrees with Embed.length", Embed.measure({ title = "ab", fields = { { name = "c", value = "de" } } }), 5)

----------------------------------------------------------------------------
-- Interaction: update is an edit; ephemeral after a public defer
----------------------------------------------------------------------------

type Log = { { route: string, data: any } }

local function fakeIx(): (any, Log)
	local log: Log = {}
	local function record(route: string, data: any)
		table.insert(log, { route = route, data = data })
	end
	local api = {
		interactions = {
			createResponse = function(_id: string, _token: string, kind: number, data: any)
				record(`respond:{kind}`, data)
			end,
			editOriginalResponse = function(_app: string, _token: string, payload: any): any
				record("editOriginal", Payload.message(payload, EDIT))
				return { id = "orig" }
			end,
			createFollowup = function(_app: string, _token: string, payload: any): any
				record("followUp", Payload.message(payload))
				return { id = "fu" }
			end,
			editFollowup = function(_app: string, _token: string, messageId: string, payload: any): any
				record(`editFollowup:{messageId}`, Payload.message(payload, EDIT))
				return { id = messageId }
			end,
			deleteOriginalResponse = function()
				record("deleteOriginal", nil)
			end,
			getOriginalResponse = function(): any
				record("getOriginal", nil)
				return { id = "orig" }
			end,
		},
	}
	local ix = Interaction.new({ api = api } :: any, {
		id = "9",
		application_id = "app",
		token = "tok",
		type = Const.InteractionType.MESSAGE_COMPONENT,
		version = 1,
		user = { id = "u", username = "u" },
		data = { custom_id = "x" },
	} :: any)
	return ix, log
end

do
	local ix, log = fakeIx()
	accepts("update with six rows (the message may be V2)", function()
		ix:update({ components = sixRows() })
	end)
	h.equals("update sent UPDATE_MESSAGE", log[1] and log[1].route, `respond:{Const.InteractionCallback.UPDATE_MESSAGE}`)
end
do
	local ix, _ = fakeIx()
	accepts("update that strips components", function()
		ix:update({ components = {} })
	end)
end

do
	local ix, log = fakeIx()
	ix:defer()
	local message = ix:replyEphemeral({ content = "secret" })
	h.equals("ephemeral after a public defer goes out as a follow-up", log[2] and log[2].route, "followUp")
	h.check("and the follow-up carries the flag", log[2] ~= nil and bit32.btest(log[2].data.flags or 0, EPHEMERAL))
	h.equals("the public placeholder is deleted", log[3] and log[3].route, "deleteOriginal")
	h.equals("the follow-up is returned", message and message.id, "fu")
	h.equals("nothing was edited into the public placeholder", #log, 3)
end
do
	local ix, log = fakeIx()
	ix:defer(true)
	ix:replyEphemeral({ content = "secret" })
	h.equals("ephemeral after an ephemeral defer edits the placeholder", log[2] and log[2].route, "editOriginal")
end
do
	local ix, log = fakeIx()
	ix:defer(true)
	ix:reply({ content = "public?" })
	h.equals("a public reply after an ephemeral defer still edits (stays ephemeral)", log[2] and log[2].route, "editOriginal")
end

----------------------------------------------------------------------------
-- Paginator: follow-up path and embed detection
----------------------------------------------------------------------------

local function collectingClient(): (any, { any })
	local captured: { any } = {}
	return {
		collect = function(_self: any, options: any)
			captured[1] = options
			return nil
		end,
	}, captured
end

do
	local ix, log = fakeIx()
	ix.acknowledged = true -- answered already, e.g. by an earlier reply
	local client, captured = collectingClient()
	Paginator.reply(client, ix, { pages = { "one", "two" } })
	local options = captured[1]
	h.equals("a follow-up paginator collects on the follow-up", options and options.messageId, "fu")
	local fetched = false
	for _, entry in log do
		if entry.route == "getOriginal" then
			fetched = true
		end
	end
	h.check("and does not fetch @original", not fetched)
	if options ~= nil then
		options.onEnd()
	end
	h.equals("expiry edits the follow-up, not @original", log[#log] and log[#log].route, "editFollowup:fu")
end
do
	local ix, log = fakeIx()
	local client, captured = collectingClient()
	Paginator.reply(client, ix, { pages = { "one", "two" } })
	local options = captured[1]
	h.equals("a first-response paginator collects on @original", options and options.messageId, "orig")
	if options ~= nil then
		options.onEnd()
	end
	h.equals("and expiry edits @original", log[#log] and log[#log].route, "editOriginal")
end
do
	local ix, log = fakeIx()
	ix:defer()
	local client, captured = collectingClient()
	Paginator.reply(client, ix, { pages = { "one", "two" } })
	local options = captured[1]
	h.equals("after a defer, the edited original is used", options and options.messageId, "orig")
	h.equals("without a fetch", log[#log] and log[#log].route, "editOriginal")
end

for _, page in {
	{ fields = { { name = "a", value = "b" } } } :: any,
	{ image = { url = "https://x/y.png" } },
	{ color = 0xff0000, footer = { text = "f" } },
} do
	local ix, log = fakeIx()
	local client = collectingClient()
	Paginator.reply(client, ix, { pages = { page, "two" } })
	local embeds: { any } = (log[1] and log[1].data.embeds) or {}
	h.equals("a title-less embed page is wrapped in embeds", #embeds, 1)
end
do
	local ix, log = fakeIx()
	local client = collectingClient()
	Paginator.reply(client, ix, { pages = { { content = "c", embeds = { { title = "t" } } }, "two" } })
	local sent = log[1] and log[1].data
	h.equals("a message payload stays a message payload", sent and sent.content, "c")
end

h.finish()
