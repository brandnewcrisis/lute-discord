--!strict
-- Components V2, the modal components, and reading modal submissions back.
-- Wire shapes are checked field by field against Discord's component
-- reference, since a wrong field name is ignored by Discord, not rejected.
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Interaction = require("@discord/interaction")
local Json = require("@discord/json")
local Paginator = require("@discord/paginator")
local Payload = require("@discord/payload")
local h = require("./harness")

local T = Const.ComponentType
local V2 = Const.MessageFlag.IS_COMPONENTS_V2

----------------------------------------------------------------------------
-- Content components
----------------------------------------------------------------------------

local text = Components.text("**hello**")
h.equals("text display type", text.type, T.TEXT_DISPLAY)
h.equals("text display content", text.content, "**hello**")
h.throws("empty text display", "needs content", function()
	Components.text("")
end)
h.throws("text display length", "limit is 4000", function()
	Components.text(string.rep("x", 4001))
end)
h.check("text display at the limit is fine", Components.text(string.rep("x", 4000)) ~= nil)

local thumb = Components.thumbnail("https://example.com/a.png", { description = "alt", spoiler = true })
h.equals("thumbnail type", thumb.type, T.THUMBNAIL)
h.equals("thumbnail media url", (thumb.media :: any).url, "https://example.com/a.png")
h.equals("thumbnail alt text", thumb.description, "alt")
h.equals("thumbnail spoiler", thumb.spoiler, true)
h.throws("thumbnail description length", "limit is 1024", function()
	Components.thumbnail("https://x", { description = string.rep("d", 1025) })
end)
h.throws("thumbnail needs a url", "needs a url", function()
	Components.thumbnail("")
end)

local gallery = Components.gallery("https://example.com/1.png", {
	url = "attachment://chart.png",
	description = "chart",
	spoiler = true,
})
h.equals("gallery type", gallery.type, T.MEDIA_GALLERY)
h.equals("gallery item count", #(gallery.items :: any), 2)
h.equals("gallery string item", (gallery.items :: any)[1].media.url, "https://example.com/1.png")
h.equals("gallery table item description", (gallery.items :: any)[2].description, "chart")
h.equals("gallery table item spoiler", (gallery.items :: any)[2].spoiler, true)
h.throws("empty gallery", "1 to 10 items", function()
	Components.gallery()
end)
h.throws("gallery over ten", "1 to 10 items, got 11", function()
	local urls = {}
	for index = 1, 11 do
		table.insert(urls, `https://example.com/{index}.png`)
	end
	Components.gallery(table.unpack(urls))
end)

local file = Components.file("attachment://report.pdf", { spoiler = true })
h.equals("file type", file.type, T.FILE)
h.equals("file reference", (file.file :: any).url, "attachment://report.pdf")
h.equals("file spoiler", file.spoiler, true)
h.throws("file takes only attachment refs", "only attachment://", function()
	Components.file("https://example.com/report.pdf")
end)

----------------------------------------------------------------------------
-- Layout components
----------------------------------------------------------------------------

local sep = Components.separator({ divider = false, spacing = "large" })
h.equals("separator type", sep.type, T.SEPARATOR)
h.equals("separator divider", sep.divider, false)
h.equals("separator spacing is the integer", sep.spacing, Const.SeparatorSpacing.LARGE)
local plain = Components.separator()
h.equals("separator defaults are left to Discord", plain.spacing, nil)
h.throws("separator spacing name", '"small" or "large"', function()
	Components.separator({ spacing = "huge" })
end)

local button = Components.button({ id = "go", label = "Go" })
local section = Components.section({ accessory = button }, "line one", Components.text("line two"))
h.equals("section type", section.type, T.SECTION)
h.equals("strings become text displays", (section.components :: any)[1].type, T.TEXT_DISPLAY)
h.equals("section keeps given text displays", (section.components :: any)[2].content, "line two")
h.equals("section accessory", (section.accessory :: any).custom_id, "go")
h.check(
	"thumbnail accessory",
	Components.section({ accessory = thumb }, "x").accessory ~= nil
)
h.throws("section text count", "1 to 3 text displays, got 4", function()
	Components.section({ accessory = button }, "a", "b", "c", "d")
end)
h.throws("section needs text", "1 to 3 text displays, got 0", function()
	Components.section({ accessory = button })
end)
h.throws("section holds only text", "only text displays", function()
	Components.section({ accessory = button }, sep)
end)
h.throws("section accessory kind", "button or a thumbnail", function()
	Components.section({ accessory = Components.text("no") }, "x")
end)
h.throws("section needs an accessory", "needs an accessory", function()
	Components.section({} :: any, "x")
end)

local container = Components.container(
	{ accent = "#5865F2", spoiler = true },
	"Heading",
	Components.separator(),
	section,
	gallery,
	file,
	Components.row(Components.button({ id = "ok", label = "OK" }))
)
h.equals("container type", container.type, T.CONTAINER)
h.equals("container accent from hex", container.accent_color, 0x5865F2)
h.equals("container spoiler", container.spoiler, true)
h.equals("container children", #(container.components :: any), 6)
h.equals("container string child is text", (container.components :: any)[1].type, T.TEXT_DISPLAY)
h.equals(
	"accent from Const.Color",
	Components.container({ accent = Const.Color.RED }, "x").accent_color,
	Const.Color.RED
)
h.equals("accent from #rgb shorthand", Components.container({ accent = "#fff" }, "x").accent_color, 0xFFFFFF)
h.equals("no accent is omitted", Components.container({}, "x").accent_color, nil)
h.throws("bad accent", "not a colour", function()
	Components.container({ accent = "blurple" }, "x")
end)
h.throws("accent out of range", "not a colour", function()
	Components.container({ accent = 0x1000000 }, "x")
end)
h.throws("empty container", "at least one", function()
	Components.container({})
end)
h.throws("no container in a container", "cannot hold a container", function()
	Components.container({}, Components.container({}, "x"))
end)
h.throws("no bare button in a container", "cannot hold a button", function()
	Components.container({}, button)
end)
h.throws("no thumbnail in a container", "cannot hold a thumbnail", function()
	Components.container({}, thumb)
end)
h.throws("container over 40 components", "V2 message allows 40", function()
	local rows = {}
	for row = 1, 8 do
		local buttons = {}
		for index = 1, 5 do
			table.insert(buttons, Components.button({ id = `b{row}:{index}`, label = "x" }))
		end
		table.insert(rows, Components.row(table.unpack(buttons)))
	end
	-- 1 container + 8 rows + 40 buttons.
	Components.container({}, table.unpack(rows))
end)

h.equals("count includes nesting and accessories", Components.count({ container }), 1 + 1 + 1 + 1 + 3 + 1 + 1 + 1 + 1)
h.check("isV2 sees text displays", Components.isV2({ text }))
h.check("isV2 is false for action rows alone", not Components.isV2({ Components.row(button) }))

----------------------------------------------------------------------------
-- Buttons and selects: limits the reference documents
----------------------------------------------------------------------------

local premium = Components.button({ sku = "123" })
h.equals("premium button style", premium.style, Const.ButtonStyle.PREMIUM)
h.equals("premium button sku", premium.sku_id, "123")
h.throws("premium button takes only a sku", "only a sku", function()
	Components.button({ sku = "123", label = "Buy" })
end)
h.throws("button label length", "limit is 80", function()
	Components.button({ id = "x", label = string.rep("l", 81) })
end)
h.throws("link url length", "limit is 512", function()
	Components.linkButton("x", "https://" .. string.rep("u", 510))
end)
h.throws("select placeholder length", "limit is 150", function()
	Components.userSelect({ id = "u", placeholder = string.rep("p", 151) })
end)
h.throws("select max range", "from 1 to 25", function()
	Components.userSelect({ id = "u", max = 26 })
end)
h.throws("select min above max", "greater than max", function()
	Components.userSelect({ id = "u", min = 3, max = 2 })
end)
h.throws("select option label length", "limit is 100", function()
	Components.select({ id = "s", options = { { label = string.rep("o", 101), value = "v" } } })
end)
local defaulted = Components.roleSelect({ id = "r", defaults = { "42" }, max = 2 })
h.equals("bare default takes the select's kind", (defaulted.default_values :: any)[1].type, "role")
h.throws("mentionable defaults need a kind", "type =", function()
	Components.mentionableSelect({ id = "m", defaults = { "1" } })
end)
h.throws("defaults within max", "at most 1 choices", function()
	Components.userSelect({ id = "u", defaults = { "1", "2" } })
end)
h.throws("string select defaults go on options", "default = true", function()
	Components.select({ id = "s", options = { { label = "a", value = "a" } }, defaults = { "a" } })
end)

----------------------------------------------------------------------------
-- Payload: the V2 flag and its conflicts
----------------------------------------------------------------------------

local auto = Payload.message({ components = { text } })
h.equals("V2 kinds set the flag", auto.flags, V2)
h.equals("the v2 key never reaches Discord", Payload.message({ v2 = true, components = { text } }).v2, nil)

local explicit = Payload.message({ v2 = true, components = { Components.row(button) } })
h.equals("v2 = true flags an action-row-only message", explicit.flags, V2)

local legacy = Payload.message({ content = "hi", components = { Components.row(button) } })
h.equals("action rows alone stay legacy", legacy.flags, nil)

local combined = Payload.message({ components = { text }, ephemeral = true })
h.equals("V2 combines with ephemeral", combined.flags, bit32.bor(V2, Const.MessageFlag.EPHEMERAL))

local preset = Payload.message({ flags = V2, components = { Components.row(button) } })
h.equals("a flag set by hand counts as V2", preset.flags, V2)

h.throws("v2 = false refuses V2 kinds", "v2 = false", function()
	Payload.message({ v2 = false, components = { text } })
end)
h.throws("V2 refuses content", "cannot carry content", function()
	Payload.message({ content = "hi", components = { text } })
end)
h.throws("V2 refuses content even when flagged by hand", "cannot carry content", function()
	Payload.message({ content = "hi", flags = V2, components = { Components.row(button) } })
end)
h.throws("V2 refuses embeds", "cannot carry embeds", function()
	Payload.message({ v2 = true, embeds = { Embed.new():setTitle("x") }, components = { text } })
end)
h.throws("V2 refuses the singular embed too", "cannot carry embeds", function()
	Payload.message({ embed = Embed.new():setTitle("x"), components = { text } })
end)
h.throws("V2 refuses polls", "cannot carry a poll", function()
	Payload.message({ components = { text }, poll = { question = { text = "?" }, answers = {} } })
end)
h.throws("V2 refuses stickers", "cannot carry stickers", function()
	Payload.message({ components = { text }, sticker_ids = { "1" } })
end)
h.check("clearing content with Json.null is not a conflict", (function()
	local body = Payload.message({ v2 = true, content = Json.null, embeds = {}, components = { text } })
	return body.flags == V2
end)())

-- Emptiness: a V2 message can show only components; a legacy one keeps the
-- old rule.
h.throws("a V2 message needs components", "at least one", function()
	Payload.message({ v2 = true })
end)
h.throws("a V2 message with only files is refused", "at least one", function()
	Payload.message({ v2 = true, files = { { name = "a.txt", data = "x" } } })
end)
h.throws("an empty legacy message is still refused", "payload is empty", function()
	Payload.message({ content = "" })
end)
h.check("a legacy message with content passes", Payload.message({ content = "x" }) ~= nil)
h.check("a V2 message with one text passes", Payload.message({ components = { text } }) ~= nil)

-- Structure checks on the whole message.
h.throws("legacy top level holds only rows", "put it in Components.row", function()
	Payload.message({ components = { button } })
end)
h.throws("legacy messages hold five rows", "at most 5 action rows", function()
	local rows = {}
	for index = 1, 6 do
		table.insert(rows, Components.row(Components.button({ id = `r{index}`, label = "x" })))
	end
	Payload.message({ components = rows })
end)
h.throws("V2 top level refuses a bare button", "top level", function()
	Payload.message({ components = { text, button } })
end)
h.throws("V2 top level refuses a thumbnail", "top level", function()
	Payload.message({ components = { text, thumb } })
end)
h.throws("V2 total counts nesting", "at most 40 components", function()
	local tree = {}
	for index = 1, 41 do
		table.insert(tree, Components.text(`line {index}`))
	end
	Payload.message({ components = tree })
end)
h.throws("hand-written rows are checked too", "not a text display", function()
	Payload.message({ components = { text, { type = T.ACTION_ROW, components = { text } } } })
end)
h.throws("custom ids must be unique", 'custom_id "go" is used twice', function()
	Payload.message({ components = { section, Components.row(button) } })
end)
h.check("unknown future kinds are passed through", (function()
	local body = Payload.message({ v2 = true, components = { text, { type = 99 } } })
	return body.components ~= nil
end)())

-- attachment:// references pair with files.
h.check("a reference to an uploaded file passes", (function()
	local body = Payload.message({
		components = { Components.gallery("attachment://chart.png") },
		files = { { name = "chart.png", data = "png" } },
	})
	return body.flags == V2
end)())
h.throws("a reference to a missing upload is caught", "attachment://nope.png", function()
	Payload.message({
		components = { Components.file("attachment://nope.png") },
		files = { { name = "chart.png", data = "png" } },
	})
end)
h.check("without files, references are left for Discord (edits keep attachments)", (function()
	return Payload.message({ components = { Components.file("attachment://old.pdf") } }) ~= nil
end)())

----------------------------------------------------------------------------
-- setDisabled walks nested trees
----------------------------------------------------------------------------

local nested = {
	Components.container(
		{},
		Components.section({ accessory = Components.button({ id = "acc", label = "A" }) }, "x"),
		Components.row(Components.button({ id = "in", label = "B" })),
		Components.row(Components.userSelect({ id = "sel" }))
	),
	Components.row(Components.button({ id = "top", label = "C" })),
	Components.text("plain"),
}
Components.setDisabled(nested, true)
local tree: any = nested
h.equals("section accessory disabled", tree[1].components[1].accessory.disabled, true)
h.equals("row inside a container disabled", tree[1].components[2].components[1].disabled, true)
h.equals("select inside a container disabled", tree[1].components[3].components[1].disabled, true)
h.equals("top-level row disabled", tree[2].components[1].disabled, true)
h.equals("containers are not given a disabled field", tree[1].disabled, nil)
h.equals("text displays are not given a disabled field", tree[3].disabled, nil)
Components.setDisabled(nested, false)
h.equals("and re-enabled", tree[1].components[1].accessory.disabled, false)

----------------------------------------------------------------------------
-- Modal components
----------------------------------------------------------------------------

local upload = Components.fileUpload({ id = "shots", min = 1, max = 3, types = { "image", ".pdf" } })
h.equals("file upload type", upload.type, T.FILE_UPLOAD)
h.equals("file upload max", upload.max_values, 3)
h.equals("file upload filter", (upload.file_types :: any)[2], ".pdf")
h.throws("file upload max range", "from 1 to 10", function()
	Components.fileUpload({ id = "f", max = 11 })
end)

local radio = Components.radioGroup({
	id = "tier",
	options = { { label = "Free", value = "free" }, { label = "Pro", value = "pro", default = true } },
})
h.equals("radio group type", radio.type, T.RADIO_GROUP)
h.equals("radio option default", (radio.options :: any)[2].default, true)
h.throws("radio needs two options", "2 to 10 options, got 1", function()
	Components.radioGroup({ id = "r", options = { { label = "a", value = "a" } } })
end)

local boxes = Components.checkboxGroup({
	id = "topics",
	options = { { label = "Bugs", value = "bugs" }, { label = "Ideas", value = "ideas" } },
	min = 0,
	max = 2,
	required = false,
})
h.equals("checkbox group type", boxes.type, T.CHECKBOX_GROUP)
h.equals("checkbox group min", boxes.min_values, 0)
h.throws("checkbox group options", "1 to 10 options, got 0", function()
	Components.checkboxGroup({ id = "c", options = {} })
end)

local tick = Components.checkbox({ id = "agree", default = true })
h.equals("checkbox type", tick.type, T.CHECKBOX)
h.equals("checkbox default", tick.default, true)

local labelled = Components.label(
	"Describe it",
	Components.textInput({ id = "body", style = "paragraph" }),
	"Steps help most"
)
h.equals("label type", labelled.type, T.LABEL)
h.equals("label text", labelled.label, "Describe it")
h.equals("label description", labelled.description, "Steps help most")
h.equals("label child", (labelled.component :: any).custom_id, "body")
h.throws("label length", "limit is 45", function()
	Components.label(string.rep("l", 46), tick)
end)
h.throws("label description length", "limit is 100", function()
	Components.label("x", tick, string.rep("d", 101))
end)
h.throws("text input inside a label has no label of its own", "must not set its own label", function()
	Components.label("x", Components.textInput({ id = "t", label = "dup" }))
end)
h.throws("no disabled in modals", "cannot set disabled", function()
	Components.label("x", Components.userSelect({ id = "u", disabled = true }))
end)
h.throws("min 0 needs required = false", "required = false", function()
	Components.label("x", Components.checkboxGroup({ id = "c", options = { { label = "a", value = "a" } }, min = 0 }))
end)
h.throws("labels wrap inputs only", "not a button", function()
	Components.label("x", button)
end)
h.throws("text input limits", "from 1 to 4000", function()
	Components.textInput({ id = "t", max = 4001 })
end)

local form = Components.modal({
	id = "report",
	title = "Bug report",
	components = {
		Components.text("Thanks for helping."),
		labelled,
		Components.label("Area", Components.select({ id = "area", options = { { label = "UI", value = "ui" } } })),
		Components.label("Screenshots", upload),
		Components.textInput({ id = "legacy", label = "Old style" }),
	},
})
h.equals("modal keeps text displays", form.components[1].type, T.TEXT_DISPLAY)
h.equals("modal keeps labels", form.components[2].type, T.LABEL)
h.equals("legacy input goes in a row", form.components[5].type, T.ACTION_ROW)
h.equals("the row holds the input", (form.components[5].components :: any)[1].custom_id, "legacy")

local legacyForm = Components.modal({
	id = "old",
	title = "Old",
	inputs = { Components.textInput({ id = "a", label = "A" }) },
})
h.equals("the inputs field still works", legacyForm.components[1].type, T.ACTION_ROW)

h.throws("modal holds five", "1 to 5 components, got 6", function()
	local many = {}
	for index = 1, 6 do
		table.insert(many, Components.text(`t{index}`))
	end
	Components.modal({ id = "m", title = "t", components = many })
end)
h.throws("a bare select must be labelled", "must be wrapped in Components.label", function()
	Components.modal({ id = "m", title = "t", components = { Components.userSelect({ id = "u" }) } })
end)
h.throws("a bare legacy input needs a label", "needs a label", function()
	Components.modal({ id = "m", title = "t", components = { Components.textInput({ id = "x" }) } })
end)
h.throws("message-only kinds stay out of modals", "cannot go in a modal", function()
	Components.modal({ id = "m", title = "t", components = { sep } })
end)
h.throws("modal title length", "limit is 45", function()
	Components.modal({ id = "m", title = string.rep("t", 46), components = { text } })
end)
h.throws("modal ids are unique", 'custom_id "a" is used twice', function()
	Components.modal({
		id = "m",
		title = "t",
		components = {
			Components.textInput({ id = "a", label = "A" }),
			Components.label("B", Components.textInput({ id = "a" })),
		},
	})
end)

----------------------------------------------------------------------------
-- Reading submissions back, in both shapes
----------------------------------------------------------------------------

local function submission(components: any, resolvedData: any?): any
	local client: any = { api = {} }
	return Interaction.new(client, {
		id = "1",
		application_id = "app",
		token = "tok",
		type = Const.InteractionType.MODAL_SUBMIT,
		version = 1,
		channel_id = "chan",
		user = { id = "u", username = "u" },
		data = { custom_id = "report", components = components, resolved = resolvedData },
	} :: any)
end

-- The shape Discord sends for a legacy modal: action rows of text inputs.
local old = submission({
	{ type = 1, id = 1, components = { { type = 4, id = 2, custom_id = "title", value = "Crash" } } },
	{ type = 1, id = 3, components = { { type = 4, id = 4, custom_id = "body", value = "On start" } } },
})
h.equals("legacy text value", old:modalValues().title, "Crash")
h.equals("legacy typed getter", old:modalValue("body"), "On start")

-- The shape for a label modal, one of each kind, as documented.
local new = submission({
	{ type = 10, id = 1 },
	{ type = 18, id = 2, component = { type = 4, id = 3, custom_id = "body", value = "Steps" } },
	{ type = 18, id = 4, component = { type = 3, id = 5, custom_id = "area", values = { "ui", "api" } } },
	{ type = 18, id = 6, component = { type = 5, id = 7, custom_id = "who", values = { "99" } } },
	{ type = 18, id = 8, component = { type = 19, id = 9, custom_id = "shots", values = { "a1", "a2" } } },
	{ type = 18, id = 10, component = { type = 21, id = 11, custom_id = "tier", value = "pro" } },
	{ type = 18, id = 12, component = { type = 22, id = 13, custom_id = "topics", values = {} } },
	{ type = 18, id = 14, component = { type = 23, id = 15, custom_id = "agree", value = true } },
	{ type = 18, id = 16, component = { type = 23, id = 17, custom_id = "spam", value = false } },
	{ type = 18, id = 18, component = { type = 6, id = 19, custom_id = "roles", values = { "7" } } },
	{ type = 18, id = 20, component = { type = 8, id = 21, custom_id = "where", values = { "c1" } } },
}, {
	users = { ["99"] = { id = "99", username = "target" } },
	roles = { ["7"] = { id = "7", name = "mod" } },
	channels = { ["c1"] = { id = "c1", name = "general" } },
	attachments = {
		a1 = { id = "a1", filename = "one.png", size = 1, url = "u", proxy_url = "p" },
		a2 = { id = "a2", filename = "two.png", size = 2, url = "u", proxy_url = "p" },
	},
})
local values = new:modalValues()
h.equals("label text value", values.body, "Steps")
h.equals("select values come back as an array", values.area[2], "api")
h.equals("radio value", values.tier, "pro")
h.equals("checkbox value is a boolean", values.agree, true)
h.equals("an unticked checkbox is false, not missing", values.spam, false)
h.equals("an empty checkbox group is an empty array", #values.topics, 0)
h.equals("modalValue reads a label's text input", new:modalValue("body"), "Steps")
h.equals("modalValue reads a radio group", new:modalValue("tier"), "pro")
h.equals("modalValue is nil for a select", new:modalValue("area"), nil)
h.equals("modalSelected", new:modalSelected("area")[1], "ui")
h.equals("modalSelected of an unknown id is empty", #new:modalSelected("nope"), 0)
h.check("modalChecked true", new:modalChecked("agree"))
h.check("modalChecked false", not new:modalChecked("spam"))
local files = new:modalFiles("shots")
h.equals("modalFiles resolves attachments", #files, 2)
h.equals("modalFiles keeps order", files[2].filename, "two.png")
h.equals("modalUsers resolves", new:modalUsers("who")[1].username, "target")
h.equals("modalRoles resolves", new:modalRoles("roles")[1].name, "mod")
h.equals("modalChannels resolves", new:modalChannels("where")[1].name, "general")

-- A radio group left empty comes back as null, which decoding turns to nil.
local unpicked = submission({ { type = 18, component = { type = 21, custom_id = "tier" } } })
h.equals("an unpicked radio is absent", unpicked:modalValues().tier, nil)
h.equals("and modalValue is nil", unpicked:modalValue("tier"), nil)

----------------------------------------------------------------------------
-- Paginator
----------------------------------------------------------------------------

-- The flag cannot be cleared on an edit, so mixed pages are refused before
-- anything is sent.
h.throws("paginator refuses mixed V2 and legacy pages", "cannot switch a message back", function()
	local noClient: any = {}
	local noIx: any = { id = "1" }
	Paginator.reply(noClient, noIx, { pages = { { components = { Components.text("v2") } }, "legacy" } })
end)

-- A V2 page keeps its own layout; the navigation row is appended to it.
do
	local sent: any = nil
	local client: any = {
		collect = function()
			return nil
		end,
	}
	local ix: any = Interaction.new({
		api = {
			interactions = {
				createResponse = function(_id: string, _token: string, _kind: number, data: any)
					sent = data
				end,
				getOriginalResponse = function(): any
					return { id = "m" }
				end,
			},
		},
	} :: any, {
		id = "9",
		application_id = "app",
		token = "tok",
		type = Const.InteractionType.APPLICATION_COMMAND,
		version = 1,
		user = { id = "u", username = "u" },
		data = { name = "pages" },
	} :: any)
	Paginator.reply(client, ix, {
		pages = { { components = { Components.text("one") } }, { components = { Components.text("two") } } },
	})
	h.equals("V2 page is flagged", sent.flags, V2)
	h.equals("page layout comes first", sent.components[1].type, T.TEXT_DISPLAY)
	h.equals("navigation row is appended", sent.components[2].type, T.ACTION_ROW)
end

h.finish()
