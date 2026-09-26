--!strict
--[[
	Message and modal components: buttons, selects, the Components V2 layout
	and content kinds (sections, text, media, containers), and the modal
	kinds (labels, text inputs, file uploads, radio and checkbox groups).

	These return plain tables in Discord's own shape rather than builder
	objects -- a component is a small, flat value and a fluent builder for it
	adds ceremony without adding safety. The safety instead comes from
	validating at construction: the layout rules (five buttons to a row, a
	select alone in its row, one to three texts in a section, which kinds a
	container may hold) and the length limits are checked here, because
	Discord reports breaking them as "Invalid form body" with a JSON path
	and no explanation.

	`custom_id` is how a component identifies itself when clicked. Namespacing
	it with a prefix -- `poll:42:yes` -- is what lets one handler serve every
	button of a kind; the router in `@discord/client` matches on prefix.

	Errors are raised at the first stack frame outside the library (see
	`@discord/blame`), so a broken limit is always reported against the line
	in the bot that built the component, however deep the helper that
	noticed it.
]]
local blame = require("@discord/blame")
local Color = require("@discord/color")
local Const = require("@discord/const")
local Spec = require("@discord/spec")
local Types = require("@discord/types")

local Components = {}

local T = Const.ComponentType

local MAX_ROWS = 5
local MAX_PER_ROW = 5
local MAX_CUSTOM_ID = 100
--- Components V2 counts every component in the tree, nested ones included.
local MAX_V2_COMPONENTS = 40
--- Modals take at most five top-level components.
local MAX_MODAL_COMPONENTS = 5

--[[
	Text display length.

	The component reference gives no per-component limit for `content`. 4000
	is what the API enforces in practice and what other libraries validate
	against; it is kept as one named value so it is a one-line change if
	Discord documents something different.
]]
local MAX_TEXT = 4000

local BUTTON_STYLES: { [string]: number } = {
	primary = Const.ButtonStyle.PRIMARY,
	secondary = Const.ButtonStyle.SECONDARY,
	success = Const.ButtonStyle.SUCCESS,
	danger = Const.ButtonStyle.DANGER,
	link = Const.ButtonStyle.LINK,
	premium = Const.ButtonStyle.PREMIUM,
}

-- Human names, for error messages that name the rule rather than the number.
local NAMES: { [number]: string } = {
	[T.ACTION_ROW] = "action row",
	[T.BUTTON] = "button",
	[T.STRING_SELECT] = "string select",
	[T.TEXT_INPUT] = "text input",
	[T.USER_SELECT] = "user select",
	[T.ROLE_SELECT] = "role select",
	[T.MENTIONABLE_SELECT] = "mentionable select",
	[T.CHANNEL_SELECT] = "channel select",
	[T.SECTION] = "section",
	[T.TEXT_DISPLAY] = "text display",
	[T.THUMBNAIL] = "thumbnail",
	[T.MEDIA_GALLERY] = "media gallery",
	[T.FILE] = "file",
	[T.SEPARATOR] = "separator",
	[T.CONTAINER] = "container",
	[T.LABEL] = "label",
	[T.FILE_UPLOAD] = "file upload",
	[T.RADIO_GROUP] = "radio group",
	[T.CHECKBOX_GROUP] = "checkbox group",
	[T.CHECKBOX] = "checkbox",
}

local function set(...: number): { [number]: boolean }
	local out = {}
	for index = 1, select("#", ...) do
		out[select(index, ...)] = true
	end
	return out
end

local SELECTS = set(T.STRING_SELECT, T.USER_SELECT, T.ROLE_SELECT, T.MENTIONABLE_SELECT, T.CHANNEL_SELECT)
-- Kinds that only exist under IS_COMPONENTS_V2; their presence settles
-- which kind of message this is.
local V2_ONLY = set(T.SECTION, T.TEXT_DISPLAY, T.THUMBNAIL, T.MEDIA_GALLERY, T.FILE, T.SEPARATOR, T.CONTAINER)
-- A thumbnail is V2-only but lives only in a section's accessory slot.
local V2_TOP_LEVEL =
	set(T.ACTION_ROW, T.TEXT_DISPLAY, T.SECTION, T.MEDIA_GALLERY, T.FILE, T.SEPARATOR, T.CONTAINER)
local CONTAINER_CHILDREN = set(T.ACTION_ROW, T.TEXT_DISPLAY, T.SECTION, T.MEDIA_GALLERY, T.SEPARATOR, T.FILE)
local SECTION_CHILDREN = set(T.TEXT_DISPLAY)
local SECTION_ACCESSORIES = set(T.BUTTON, T.THUMBNAIL)
local ROW_CHILDREN = set(T.BUTTON, T.STRING_SELECT, T.USER_SELECT, T.ROLE_SELECT, T.MENTIONABLE_SELECT, T.CHANNEL_SELECT)
local LABEL_CHILDREN = set(
	T.TEXT_INPUT,
	T.STRING_SELECT,
	T.USER_SELECT,
	T.ROLE_SELECT,
	T.MENTIONABLE_SELECT,
	T.CHANNEL_SELECT,
	T.FILE_UPLOAD,
	T.RADIO_GROUP,
	T.CHECKBOX_GROUP,
	T.CHECKBOX
)
-- Kinds that can be switched off. Setting `disabled` on anything else is an
-- unknown field at best.
local DISABLEABLE = set(T.BUTTON, T.STRING_SELECT, T.USER_SELECT, T.ROLE_SELECT, T.MENTIONABLE_SELECT, T.CHANNEL_SELECT)

--[[
	Key sets for `Spec.check`, one per spec shape, and the aliases that map
	Discord's wire names onto this library's. The wire names are the likely
	slip: they are what the API reference and every JSON example show, and
	passing one here typechecks, runs, and is silently dropped.
]]
local ID_ALIAS = { custom_id = "id" }
local RANGE_ALIASES = { custom_id = "id", min_values = "min", max_values = "max" }

local BUTTON_KEYS = Spec.keys({ "id", "label", "style", "emoji", "url", "sku", "disabled" })
local BUTTON_ALIASES = { custom_id = "id", sku_id = "sku" }

local SELECT_KEYS =
	Spec.keys({ "id", "placeholder", "options", "min", "max", "disabled", "channelTypes", "required", "defaults" })
local SELECT_ALIASES = {
	custom_id = "id",
	min_values = "min",
	max_values = "max",
	default_values = "defaults",
	channel_types = "channelTypes",
}
local SELECT_OPTION_KEYS = Spec.keys({ "label", "value", "description", "emoji", "default" })
local CHOICE_OPTION_KEYS = Spec.keys({ "label", "value", "description", "default" })

local TEXT_INPUT_KEYS = Spec.keys({ "id", "label", "style", "placeholder", "value", "min", "max", "required" })
local TEXT_INPUT_ALIASES = { custom_id = "id", min_length = "min", max_length = "max" }

local MEDIA_KEYS = Spec.keys({ "description", "spoiler" })
local MEDIA_ALIASES = { alt = "description" }
local GALLERY_ITEM_KEYS = Spec.keys({ "url", "description", "spoiler" })
local FILE_KEYS = Spec.keys({ "spoiler" })
local SEPARATOR_KEYS = Spec.keys({ "divider", "spacing" })
local SECTION_KEYS = Spec.keys({ "accessory" })
local CONTAINER_KEYS = Spec.keys({ "accent", "spoiler" })
local CONTAINER_ALIASES = { accent_color = "accent", color = "accent", colour = "accent" }

local FILE_UPLOAD_KEYS = Spec.keys({ "id", "min", "max", "required", "types" })
local FILE_UPLOAD_ALIASES = { custom_id = "id", min_values = "min", max_values = "max", file_types = "types" }
local RADIO_GROUP_KEYS = Spec.keys({ "id", "options", "required" })
local CHECKBOX_GROUP_KEYS = Spec.keys({ "id", "options", "min", "max", "required" })
local CHECKBOX_KEYS = Spec.keys({ "id", "default" })
local MODAL_KEYS = Spec.keys({ "id", "title", "components", "inputs" })

local function name(kind: number): string
	return NAMES[kind] or `component type {kind}`
end

local function chars(text: string): number
	return utf8.len(text) or #text
end

local function checkLength(what: string, text: string?, limit: number)
	if text == nil then
		return
	end
	local length = chars(text)
	if length > limit then
		error(`{what} is {length} characters, limit is {limit}`, blame())
	end
end

local function checkRange(what: string, value: number?, low: number, high: number)
	if value == nil then
		return
	end
	if value ~= math.floor(value) or value < low or value > high then
		error(`{what} must be a whole number from {low} to {high}, got {value}`, blame())
	end
end

-- Discord's limits are in characters, so a multi-byte id is measured with
-- `chars`, like every other length here, not with `#`.
local function checkId(id: string)
	local length = chars(id)
	if length > MAX_CUSTOM_ID then
		error(`custom_id is {length} characters, limit is {MAX_CUSTOM_ID}`, blame())
	end
	if id == "" then
		error("custom_id must not be empty", blame())
	end
end

export type EmojiRef = string | { id: string?, name: string?, animated: boolean? }

--- Accepts `"🔥"`, `"name:123"`, or an explicit table.
local function emoji(value: EmojiRef?): Types.Emoji?
	if value == nil then
		return nil
	end
	if type(value) == "table" then
		return { id = value.id, name = value.name, animated = value.animated }
	end
	local emojiName, id = string.match(value, "^([%w_]+):(%d+)$")
	if id ~= nil then
		return { name = emojiName, id = id }
	end
	return { name = value }
end

Components.emoji = emoji

----------------------------------------------------------------------------
-- Buttons
----------------------------------------------------------------------------

export type ButtonSpec = {
	id: string?,
	label: string?,
	style: string?,
	emoji: EmojiRef?,
	url: string?,
	--- Premium buttons only: the SKU the button sells.
	sku: string?,
	disabled: boolean?,
}

--[[
	A button.

	Exactly one of `id`, `url` and `sku` applies: a link button carries a URL
	and a premium button a SKU, and neither produces an interaction; every
	other style carries a custom id and always does. Mixing them is a 400.
]]
function Components.button(spec: ButtonSpec): Types.Component
	Spec.check(spec, BUTTON_KEYS, "button", BUTTON_ALIASES)
	local default = if spec.sku then "premium" elseif spec.url then "link" else "primary"
	local style = BUTTON_STYLES[spec.style or default]
	if style == nil then
		error(`unknown button style "{tostring(spec.style)}"`, blame())
	end
	if style == Const.ButtonStyle.PREMIUM then
		-- Discord draws a premium button itself, from the SKU; anything else
		-- set on it is rejected.
		if spec.sku == nil then
			error("a premium button needs a sku", blame())
		end
		if spec.id ~= nil or spec.label ~= nil or spec.url ~= nil or spec.emoji ~= nil then
			error("a premium button takes only a sku: no id, label, url or emoji", blame())
		end
		return { type = T.BUTTON, style = style, sku_id = spec.sku, disabled = spec.disabled }
	end
	if spec.label == nil and spec.emoji == nil then
		error("a button needs a label, an emoji, or both", blame())
	end
	checkLength("button label", spec.label, 80)
	if style == Const.ButtonStyle.LINK then
		if spec.url == nil then
			error("a link button needs a url", blame())
		end
		checkLength("button url", spec.url, 512)
		return {
			type = T.BUTTON,
			style = style,
			label = spec.label,
			emoji = emoji(spec.emoji),
			url = spec.url,
			disabled = spec.disabled,
		}
	end
	if spec.id == nil then
		error("a button needs an id (or a url, for a link button)", blame())
	end
	checkId(spec.id)
	return {
		type = T.BUTTON,
		style = style,
		label = spec.label,
		emoji = emoji(spec.emoji),
		custom_id = spec.id,
		disabled = spec.disabled,
	}
end

function Components.linkButton(label: string, url: string, emojiRef: EmojiRef?): Types.Component
	return Components.button({ label = label, url = url, emoji = emojiRef, style = "link" })
end

----------------------------------------------------------------------------
-- Selects
----------------------------------------------------------------------------

export type SelectOption = {
	label: string,
	value: string,
	description: string?,
	emoji: EmojiRef?,
	default: boolean?,
}

--- A pre-selected id. A bare string takes its kind from the select it is
--- in; a mentionable select needs the table form, since an id alone does
--- not say whether it is a user or a role.
export type SelectDefault = string | { id: string, type: string }

export type SelectSpec = {
	id: string,
	placeholder: string?,
	options: { SelectOption }?,
	min: number?,
	max: number?,
	disabled: boolean?,
	--- Channel selects only: restrict to these channel types.
	channelTypes: { number }?,
	--- Modals only: whether an answer is needed to submit. Discord's
	--- default is true; ignored in messages.
	required: boolean?,
	--- User, role, mentionable and channel selects: pre-selected ids.
	defaults: { SelectDefault }?,
}

local DEFAULT_KIND: { [number]: string } = {
	[T.USER_SELECT] = "user",
	[T.ROLE_SELECT] = "role",
	[T.CHANNEL_SELECT] = "channel",
}

local function option(what: string, spec: SelectOption): Types.SelectOption
	checkLength(`{what} label`, spec.label, 100)
	checkLength(`{what} value`, spec.value, 100)
	checkLength(`{what} description`, spec.description, 100)
	return {
		label = spec.label,
		value = spec.value,
		description = spec.description,
		emoji = emoji(spec.emoji),
		default = spec.default,
	}
end

local function select(kind: number, spec: SelectSpec): Types.Component
	Spec.check(spec, SELECT_KEYS, name(kind), SELECT_ALIASES)
	checkId(spec.id)
	checkLength("select placeholder", spec.placeholder, 150)
	checkRange("select min", spec.min, 0, 25)
	checkRange("select max", spec.max, 1, 25)
	if spec.min ~= nil and spec.max ~= nil and spec.min > spec.max then
		error(`select min ({spec.min}) is greater than max ({spec.max})`, blame())
	end
	local options: { Types.SelectOption }? = nil
	if spec.options ~= nil then
		if #spec.options == 0 or #spec.options > 25 then
			error(`a string select takes 1 to 25 options, got {#spec.options}`, blame())
		end
		local built: { Types.SelectOption } = {}
		options = built
		for _, entry in spec.options do
			Spec.check(entry, SELECT_OPTION_KEYS, "select option")
			table.insert(built, option("select option", entry))
		end
	end
	local defaults: { Types.SelectDefaultValue }? = nil
	if spec.defaults ~= nil then
		if kind == T.STRING_SELECT then
			error("a string select marks defaults with `default = true` on an option, not `defaults`", blame())
		end
		--[[
			The reference: "number of default values must be in the range
			defined by min_values and max_values", both of which default to
			one. An empty list is no defaults at all and is left alone.
		]]
		if #spec.defaults > (spec.max or 1) then
			error(`{#spec.defaults} defaults but the select allows at most {spec.max or 1} choices`, blame())
		end
		if #spec.defaults > 0 and #spec.defaults < (spec.min or 1) then
			error(`{#spec.defaults} defaults but the select needs at least {spec.min or 1} choices`, blame())
		end
		local built: { Types.SelectDefaultValue } = {}
		defaults = built
		for _, entry in spec.defaults do
			if type(entry) == "string" then
				local defaultKind = DEFAULT_KIND[kind]
				if defaultKind == nil then
					error('a mentionable select needs defaults as { id = ..., type = "user" | "role" }', blame())
				end
				table.insert(built, { id = entry, type = defaultKind })
			else
				table.insert(built, { id = entry.id, type = entry.type })
			end
		end
	end
	return {
		type = kind,
		custom_id = spec.id,
		placeholder = spec.placeholder,
		options = options,
		min_values = spec.min,
		max_values = spec.max,
		disabled = spec.disabled,
		required = spec.required,
		channel_types = spec.channelTypes,
		default_values = defaults,
	}
end

--- A menu of your own options. The chosen values arrive as `data.values`.
function Components.select(spec: SelectSpec): Types.Component
	-- Checked here as well as in `select`, so a misspelt `options` is
	-- reported as the typo rather than as "needs options".
	Spec.check(spec, SELECT_KEYS, "string select", SELECT_ALIASES)
	if spec.options == nil then
		error("a string select needs options; use userSelect/roleSelect/channelSelect for the others", blame())
	end
	return select(T.STRING_SELECT, spec)
end

--- Discord populates these itself, and fills `data.resolved` with the picked
--- objects -- no extra fetch needed.
function Components.userSelect(spec: SelectSpec): Types.Component
	return select(T.USER_SELECT, spec)
end

function Components.roleSelect(spec: SelectSpec): Types.Component
	return select(T.ROLE_SELECT, spec)
end

function Components.mentionableSelect(spec: SelectSpec): Types.Component
	return select(T.MENTIONABLE_SELECT, spec)
end

function Components.channelSelect(spec: SelectSpec): Types.Component
	return select(T.CHANNEL_SELECT, spec)
end

----------------------------------------------------------------------------
-- Action rows
----------------------------------------------------------------------------

--[[
	One row of components.

	A select menu takes a whole row to itself; buttons pack up to five. Both
	rules are Discord's, and both are enforced here so the error names the
	rule instead of a JSON path.
]]
function Components.row(...: Types.Component): Types.ActionRow
	local children: { Types.Component } = { ... }
	if #children == 0 then
		error("an action row needs at least one component", blame())
	end
	if #children > MAX_PER_ROW then
		error(`an action row holds at most {MAX_PER_ROW} components, got {#children}`, blame())
	end
	for _, child in children do
		if child.type ~= T.BUTTON and #children > 1 then
			error("a select menu or text input must be alone in its row", blame())
		end
	end
	return { type = T.ACTION_ROW, components = children }
end

--- Packs a flat list of buttons into as many rows as it takes.
function Components.rows(children: { Types.Component }): { Types.ActionRow }
	if #children > MAX_ROWS * MAX_PER_ROW then
		error(`a message holds at most {MAX_ROWS * MAX_PER_ROW} components, got {#children}`, blame())
	end
	local out: { Types.ActionRow } = {}
	local current: { Types.Component } = {}
	for _, child in children do
		if child.type ~= T.BUTTON then
			if #current > 0 then
				table.insert(out, Components.row(table.unpack(current)))
				current = {}
			end
			table.insert(out, Components.row(child))
			continue
		end
		table.insert(current, child)
		if #current == MAX_PER_ROW then
			table.insert(out, Components.row(table.unpack(current)))
			current = {}
		end
	end
	if #current > 0 then
		table.insert(out, Components.row(table.unpack(current)))
	end
	return out
end

----------------------------------------------------------------------------
-- Components V2: content
----------------------------------------------------------------------------

--[[
	Markdown text, the V2 replacement for `content`. Mentions in it ping by
	the message's `allowed_mentions`, exactly as `content` would -- so
	anything echoing user input still wants `Payload.NO_MENTIONS`.
]]
function Components.text(content: string): Types.Component
	if content == "" then
		error("a text display needs content; Discord rejects an empty one", blame())
	end
	checkLength("text display content", content, MAX_TEXT)
	return { type = T.TEXT_DISPLAY, content = content }
end

local function media(url: string): Types.UnfurledMedia
	if url == "" then
		error("media needs a url, or attachment://<filename> for an upload", blame())
	end
	return { url = url }
end

export type MediaOptions = {
	--- Alt text; max 1024 characters.
	description: string?,
	spoiler: boolean?,
}

--- A small image, usable only as a section's accessory. Images only: GIF
--- and WEBP animate, video is not supported.
function Components.thumbnail(url: string, options: MediaOptions?): Types.Component
	Spec.check(options, MEDIA_KEYS, "thumbnail", MEDIA_ALIASES)
	local opts: MediaOptions = options or {}
	checkLength("thumbnail description", opts.description, 1024)
	return {
		type = T.THUMBNAIL,
		media = media(url),
		description = opts.description,
		spoiler = opts.spoiler,
	}
end

--- A gallery entry: a url, or a url with alt text and a spoiler flag.
export type GalleryItem = string | { url: string, description: string?, spoiler: boolean? }

--- One to ten images or videos, laid out as a grid.
function Components.gallery(...: GalleryItem): Types.Component
	local given: { GalleryItem } = { ... }
	if #given == 0 or #given > 10 then
		error(`a media gallery takes 1 to 10 items, got {#given}`, blame())
	end
	local items: { Types.MediaGalleryItem } = {}
	for _, item in given do
		if type(item) == "string" then
			table.insert(items, { media = media(item) })
		else
			Spec.check(item, GALLERY_ITEM_KEYS, "gallery item", MEDIA_ALIASES)
			checkLength("gallery item description", item.description, 1024)
			table.insert(items, { media = media(item.url), description = item.description, spoiler = item.spoiler })
		end
	end
	return { type = T.MEDIA_GALLERY, items = items }
end

--[[
	An uploaded file, shown as a download card.

	Unlike thumbnails and galleries, a file component takes ONLY an
	`attachment://<filename>` reference, naming a file in the same
	payload's `files`. A URL here is rejected by Discord.
]]
function Components.file(url: string, options: { spoiler: boolean? }?): Types.Component
	Spec.check(options, FILE_KEYS, "file")
	if string.match(url, "^attachment://.+") == nil then
		error(`a file component takes only attachment://<filename>, got "{url}"`, blame())
	end
	return { type = T.FILE, file = { url = url }, spoiler = if options then options.spoiler else nil }
end

----------------------------------------------------------------------------
-- Components V2: layout
----------------------------------------------------------------------------

local SPACING: { [string]: number } = {
	small = Const.SeparatorSpacing.SMALL,
	large = Const.SeparatorSpacing.LARGE,
}

export type SeparatorSpec = {
	--- Draw a line. Discord's default is true.
	divider: boolean?,
	--- "small" (the default) or "large".
	spacing: string?,
}

--- Vertical space between components, with or without a line.
function Components.separator(spec: SeparatorSpec?): Types.Component
	Spec.check(spec, SEPARATOR_KEYS, "separator")
	local opts: SeparatorSpec = spec or {}
	local spacing: number? = nil
	if opts.spacing ~= nil then
		spacing = SPACING[opts.spacing]
		if spacing == nil then
			error(`separator spacing is "small" or "large", got "{opts.spacing}"`, blame())
		end
	end
	return { type = T.SEPARATOR, divider = opts.divider, spacing = spacing }
end

--- A child given as a string becomes a text display, which is what a bare
--- string inside a layout can only mean.
local function child(value: string | Types.Component): Types.Component
	if type(value) == "string" then
		if value == "" then
			error("a text display needs content; Discord rejects an empty one", blame())
		end
		checkLength("text display content", value, MAX_TEXT)
		return { type = T.TEXT_DISPLAY, content = value }
	end
	return value
end

--- Every component in a tree, nested ones included -- the count V2's
--- 40-component limit is measured in.
function Components.count(components: { Types.Component }): number
	local total = 0
	local function visit(node: Types.Component)
		total += 1
		for _, inner in node.components or {} do
			visit(inner)
		end
		if node.accessory ~= nil then
			visit(node.accessory)
		end
		if node.component ~= nil then
			visit(node.component)
		end
	end
	for _, node in components do
		visit(node)
	end
	return total
end

export type SectionSpec = {
	--- The button or thumbnail shown beside the text.
	accessory: Types.Component,
}

--[[
	One to three texts with a button or thumbnail beside them.

	`Components.section({ accessory = Components.thumbnail(url) }, "**Title**",
	"Body")`. Strings become text displays. The accessory is required;
	Discord has no section without one, and plain text is just `text`.
]]
function Components.section(spec: SectionSpec, ...: string | Types.Component): Types.Component
	Spec.check(spec, SECTION_KEYS, "section")
	local given: { string | Types.Component } = { ... }
	if #given == 0 or #given > 3 then
		error(`a section takes 1 to 3 text displays, got {#given}`, blame())
	end
	local children: { Types.Component } = {}
	for _, value in given do
		local built = child(value)
		if not SECTION_CHILDREN[built.type] then
			error(`a section holds only text displays, got a {name(built.type)}`, blame())
		end
		table.insert(children, built)
	end
	local accessory = spec.accessory
	if accessory == nil then
		error("a section needs an accessory: a button or a thumbnail", blame())
	end
	if not SECTION_ACCESSORIES[accessory.type] then
		error(`a section accessory is a button or a thumbnail, got a {name(accessory.type)}`, blame())
	end
	return { type = T.SECTION, components = children, accessory = accessory }
end

export type ContainerSpec = {
	--- The bar down the left edge. A number, a `Const.Color` entry, or
	--- "#rrggbb" -- the same inputs `Embed.setColor` takes.
	accent: Color.ColorInput?,
	spoiler: boolean?,
}

--[[
	A boxed group, the V2 counterpart of an embed.

	`Components.container({ accent = "#5865F2" }, "Heading", Components.separator(),
	Components.row(...))`. Holds action rows, text, sections, galleries,
	separators and files -- not another container, and not a bare button.
]]
function Components.container(spec: ContainerSpec, ...: string | Types.Component): Types.Component
	Spec.check(spec, CONTAINER_KEYS, "container", CONTAINER_ALIASES)
	local given: { string | Types.Component } = { ... }
	if #given == 0 then
		error("a container needs at least one component", blame())
	end
	local accent: number? = nil
	if spec.accent ~= nil then
		accent = Color.resolve(spec.accent)
		if accent == nil then
			error(`container accent "{tostring(spec.accent)}" is not a colour: use 0x000000-0xFFFFFF or "#rrggbb"`, blame())
		end
	end
	local children: { Types.Component } = {}
	for _, value in given do
		local built = child(value)
		if not CONTAINER_CHILDREN[built.type] then
			error(`a container cannot hold a {name(built.type)}`, blame())
		end
		table.insert(children, built)
	end
	local node: Types.Component =
		{ type = T.CONTAINER, components = children, accent_color = accent, spoiler = spec.spoiler }
	-- The message-wide check happens again in `@discord/payload`, but one
	-- oversized container is worth catching where it was built.
	local total = Components.count({ node })
	if total > MAX_V2_COMPONENTS then
		error(`container holds {total} components, a V2 message allows {MAX_V2_COMPONENTS} in total`, blame())
	end
	return node
end

----------------------------------------------------------------------------
-- Modal components
----------------------------------------------------------------------------

export type TextInputSpec = {
	id: string,
	--- Only for a bare input in a legacy modal row. Inside
	--- `Components.label` the label carries the text instead.
	label: string?,
	style: string?,
	placeholder: string?,
	value: string?,
	min: number?,
	max: number?,
	required: boolean?,
}

function Components.textInput(spec: TextInputSpec): Types.Component
	Spec.check(spec, TEXT_INPUT_KEYS, "text input", TEXT_INPUT_ALIASES)
	checkId(spec.id)
	checkLength("text input label", spec.label, 45)
	checkLength("text input placeholder", spec.placeholder, 100)
	checkLength("text input value", spec.value, 4000)
	checkRange("text input min", spec.min, 0, 4000)
	checkRange("text input max", spec.max, 1, 4000)
	local style = if spec.style == "paragraph" then Const.TextInputStyle.PARAGRAPH else Const.TextInputStyle.SHORT
	return {
		type = T.TEXT_INPUT,
		custom_id = spec.id,
		label = spec.label,
		style = style,
		placeholder = spec.placeholder,
		value = spec.value,
		min_length = spec.min,
		max_length = spec.max,
		required = spec.required,
	}
end

export type FileUploadSpec = {
	id: string,
	--- 0 to 10; Discord's default is 1.
	min: number?,
	--- 1 to 10; Discord's default is 1.
	max: number?,
	required: boolean?,
	--- `image`, `video`, `audio`, or dot-prefixed extensions like `.pdf`.
	--- Matched on extension only, so this is a hint, not a check.
	types: { string }?,
}

--- Lets the user attach files to a modal. Read them back with
--- `Interaction.modalFiles`.
function Components.fileUpload(spec: FileUploadSpec): Types.Component
	Spec.check(spec, FILE_UPLOAD_KEYS, "file upload", FILE_UPLOAD_ALIASES)
	checkId(spec.id)
	checkRange("file upload min", spec.min, 0, 10)
	checkRange("file upload max", spec.max, 1, 10)
	if spec.min ~= nil and spec.max ~= nil and spec.min > spec.max then
		error(`file upload min ({spec.min}) is greater than max ({spec.max})`, blame())
	end
	if spec.types ~= nil and #spec.types > 10 then
		error(`a file upload filters on at most 10 file types, got {#spec.types}`, blame())
	end
	return {
		type = T.FILE_UPLOAD,
		custom_id = spec.id,
		min_values = spec.min,
		max_values = spec.max,
		required = spec.required,
		file_types = spec.types,
	}
end

--- An option in a radio or checkbox group. Same limits as a select
--- option, minus the emoji.
export type ChoiceOption = {
	label: string,
	value: string,
	description: string?,
	default: boolean?,
}

local function choices(what: string, given: { ChoiceOption }, low: number): { Types.SelectOption }
	if #given < low or #given > 10 then
		error(`a {what} takes {low} to 10 options, got {#given}`, blame())
	end
	local out: { Types.SelectOption } = {}
	for _, entry in given do
		Spec.check(entry, CHOICE_OPTION_KEYS, `{what} option`)
		local built = option(`{what} option`, {
			label = entry.label,
			value = entry.value,
			description = entry.description,
			default = entry.default,
		})
		table.insert(out, built)
	end
	return out
end

export type RadioGroupSpec = {
	id: string,
	options: { ChoiceOption },
	required: boolean?,
}

--- Exactly one of two to ten options. Read with `Interaction.modalValue`.
function Components.radioGroup(spec: RadioGroupSpec): Types.Component
	Spec.check(spec, RADIO_GROUP_KEYS, "radio group", ID_ALIAS)
	checkId(spec.id)
	return {
		type = T.RADIO_GROUP,
		custom_id = spec.id,
		options = choices("radio group", spec.options, 2),
		required = spec.required,
	}
end

export type CheckboxGroupSpec = {
	id: string,
	options: { ChoiceOption },
	min: number?,
	max: number?,
	required: boolean?,
}

--- Any number of one to ten options. Read with `Interaction.modalSelected`.
function Components.checkboxGroup(spec: CheckboxGroupSpec): Types.Component
	Spec.check(spec, CHECKBOX_GROUP_KEYS, "checkbox group", RANGE_ALIASES)
	checkId(spec.id)
	checkRange("checkbox group min", spec.min, 0, 10)
	checkRange("checkbox group max", spec.max, 1, 10)
	if spec.min ~= nil and spec.max ~= nil and spec.min > spec.max then
		error(`checkbox group min ({spec.min}) is greater than max ({spec.max})`, blame())
	end
	return {
		type = T.CHECKBOX_GROUP,
		custom_id = spec.id,
		options = choices("checkbox group", spec.options, 1),
		min_values = spec.min,
		max_values = spec.max,
		required = spec.required,
	}
end

--[[
	A single yes/no box. Read with `Interaction.modalChecked`.

	A checkbox cannot be required -- Discord has no such field for it. A
	one-option `checkboxGroup` with `required = true` is the documented way
	to make someone tick a box.
]]
function Components.checkbox(spec: { id: string, default: boolean? }): Types.Component
	Spec.check(spec, CHECKBOX_KEYS, "checkbox", ID_ALIAS)
	checkId(spec.id)
	return { type = T.CHECKBOX, custom_id = spec.id, default = spec.default }
end

--[[
	A labelled field in a modal: the current way to put any input there.

	`Components.label("What went wrong?", Components.textInput({ id = "body",
	style = "paragraph" }), "Steps to reproduce help most")`.

	The modal-only rules are checked here, since this is the one place a
	component is known to be headed for a modal: no `disabled` (Discord
	errors), no label on the text input itself (the label carries it), and
	`min = 0` only alongside `required = false`.
]]
function Components.label(text: string, component: Types.Component, description: string?): Types.Component
	if text == "" then
		error("a label needs text", blame())
	end
	checkLength("label", text, 45)
	checkLength("label description", description, 100)
	if not LABEL_CHILDREN[component.type] then
		error(`a label wraps a text input, select, file upload, radio group or checkbox, not a {name(component.type)}`, blame())
	end
	if component.type == T.TEXT_INPUT and component.label ~= nil then
		error("a text input inside a label must not set its own label; the label carries the text", blame())
	end
	if component.disabled ~= nil then
		error(`a {name(component.type)} in a modal cannot set disabled; modals have no disabled components`, blame())
	end
	if component.min_values == 0 and component.required ~= false then
		error(`a {name(component.type)} with min = 0 must also set required = false`, blame())
	end
	return { type = T.LABEL, label = text, description = description, component = component }
end

export type ModalSpec = {
	id: string,
	title: string,
	--- Labels, text displays, or bare text inputs (legacy; each is put in
	--- its own action row, and needs its own `label`).
	components: { Types.Component }?,
	--- The older name for `components`, still accepted.
	inputs: { Types.Component }?,
}

-- Custom ids must be unique across a modal or a message.
local function duplicateId(components: { Types.Component }): string?
	local seen: { [string]: boolean } = {}
	local found: string? = nil
	local function visit(node: Types.Component)
		local id = node.custom_id
		if id ~= nil then
			if seen[id] and found == nil then
				found = id
			end
			seen[id] = true
		end
		for _, inner in node.components or {} do
			visit(inner)
		end
		if node.accessory ~= nil then
			visit(node.accessory)
		end
		if node.component ~= nil then
			visit(node.component)
		end
	end
	for _, node in components do
		visit(node)
	end
	return found
end

--[[
	A modal form.

	Modals are the one response that cannot follow a defer -- they must be the
	FIRST reply to an interaction, within the three-second window. A deferred
	interaction can never show one.

	Two shapes are accepted and can be mixed. The current one is labels
	(`Components.label`) and text displays. The legacy one is a bare text
	input with its own `label`, which goes into an action row as before;
	Discord has deprecated that shape but still accepts it, and every
	existing bot uses it.
]]
function Components.modal(spec: ModalSpec): Types.Modal
	Spec.check(spec, MODAL_KEYS, "modal", ID_ALIAS)
	checkId(spec.id)
	if spec.title == "" then
		error("a modal needs a title", blame())
	end
	checkLength("modal title", spec.title, 45)
	if spec.components ~= nil and spec.inputs ~= nil then
		error("pass a modal's children as `components` or `inputs`, not both", blame())
	end
	local given: { Types.Component } = spec.components or spec.inputs or {}
	if #given == 0 or #given > MAX_MODAL_COMPONENTS then
		error(`a modal takes 1 to {MAX_MODAL_COMPONENTS} components, got {#given}`, blame())
	end
	local out: { Types.Component } = {}
	for _, node in given do
		local kind = node.type
		if kind == T.TEXT_INPUT then
			if node.label == nil then
				error("a bare text input in a modal needs a label; or wrap it in Components.label", blame())
			end
			local row: Types.Component = { type = T.ACTION_ROW, components = { node } }
			table.insert(out, row)
		elseif kind == T.ACTION_ROW then
			local inner = node.components or {}
			if #inner ~= 1 or inner[1].type ~= T.TEXT_INPUT then
				error("an action row in a modal holds exactly one text input; use Components.label for anything else", blame())
			end
			table.insert(out, node)
		elseif kind == T.LABEL or kind == T.TEXT_DISPLAY then
			table.insert(out, node)
		elseif LABEL_CHILDREN[kind] then
			error(`a {name(kind)} in a modal must be wrapped in Components.label`, blame())
		else
			error(`a {name(kind)} cannot go in a modal`, blame())
		end
	end
	local dup = duplicateId(out)
	if dup ~= nil then
		error(`custom_id "{dup}" is used twice in this modal; Discord requires them unique`, blame())
	end
	return { custom_id = spec.id, title = spec.title, components = out }
end

----------------------------------------------------------------------------
-- Whole trees
----------------------------------------------------------------------------

--[[
	Whether a message's components need IS_COMPONENTS_V2.

	Only the top level is looked at: every V2-only kind that can appear
	deeper sits inside a section or container, which is itself V2-only. An
	all-action-row list returns false, since those are valid either way.
	Anything that is not a table -- `Json.null` on an edit, which clears the
	components -- has no components and so no V2 kinds.
]]
function Components.isV2(components: { Types.Component }): boolean
	if type(components) ~= "table" then
		return false
	end
	for _, node in components do
		if V2_ONLY[node.type] then
			return true
		end
	end
	return false
end

--[[
	The structural problem with a message's components, or nil.

	Unknown kinds are counted but otherwise waved through: if Discord adds a
	component this library has not heard of, a hand-written table using it
	should reach Discord and be judged there rather than refused here.
]]
local function problem(components: { Types.Component }, v2: boolean): string?
	for _, node in components do
		local kind = node.type
		if NAMES[kind] == nil then
			continue
		end
		if v2 then
			if not V2_TOP_LEVEL[kind] then
				return `a {name(kind)} cannot sit at the top level of a message`
					.. (if kind == T.BUTTON or SELECTS[kind] then "; put it in Components.row" else "")
			end
		elseif kind ~= T.ACTION_ROW then
			return `a {name(kind)} cannot sit at the top level of a message; put it in Components.row`
		end
	end
	if not v2 and #components > MAX_ROWS then
		return `a message holds at most {MAX_ROWS} action rows, got {#components}`
	end
	if v2 then
		local total = Components.count(components)
		if total > MAX_V2_COMPONENTS then
			return `a V2 message holds at most {MAX_V2_COMPONENTS} components counting nested ones, got {total}`
		end
	end

	local found: string? = nil
	local function visit(node: Types.Component)
		if found ~= nil then
			return
		end
		local kind = node.type
		local inner = node.components or {}
		if kind == T.ACTION_ROW then
			-- Only the ceiling: the reference states no minimum for a row,
			-- and `Components.row` already refuses an empty one it builds.
			if #inner > MAX_PER_ROW then
				found = `an action row holds at most {MAX_PER_ROW} components, got {#inner}`
				return
			end
			for _, item in inner do
				if NAMES[item.type] ~= nil and not ROW_CHILDREN[item.type] then
					found = `an action row in a message holds buttons or one select, not a {name(item.type)}`
					return
				end
				if SELECTS[item.type] and #inner > 1 then
					found = "a select menu must be alone in its row"
					return
				end
			end
		elseif kind == T.CONTAINER then
			for _, item in inner do
				if NAMES[item.type] ~= nil and not CONTAINER_CHILDREN[item.type] then
					found = `a container cannot hold a {name(item.type)}`
					return
				end
			end
		elseif kind == T.SECTION then
			if #inner == 0 or #inner > 3 then
				found = `a section takes 1 to 3 text displays, got {#inner}`
				return
			end
			local accessory = node.accessory
			if accessory == nil or (NAMES[accessory.type] ~= nil and not SECTION_ACCESSORIES[accessory.type]) then
				found = "a section needs an accessory: a button or a thumbnail"
				return
			end
		end
		for _, item in inner do
			visit(item)
		end
	end
	for _, node in components do
		visit(node)
	end
	if found ~= nil then
		return found
	end

	local dup = duplicateId(components)
	if dup ~= nil then
		return `custom_id "{dup}" is used twice in this message; Discord requires them unique`
	end
	return nil
end

--[[
	Checks a message's components against Discord's layout rules: five
	action rows and nothing else for a legacy message, the V2 top-level
	kinds and the 40-component total for a V2 one, plus what each layout
	may hold and unique custom ids for both. `@discord/payload` runs this on
	every outgoing message, which is what catches hand-written tables the
	constructors never saw.
]]
function Components.validate(components: { Types.Component }, v2: boolean)
	-- `Json.null` (an edit clearing them) has no structure to check.
	if type(components) ~= "table" then
		return
	end
	local message = problem(components, v2)
	if message ~= nil then
		error(message, blame())
	end
end

--[[
	Walks every component in a message, however deeply nested, and flips
	`disabled` on the ones that have it: buttons (including a section's
	accessory) and selects. What you call on a poll or a paginator once it
	has expired, so the buttons stop lying.
]]
function Components.setDisabled(components: { Types.Component }, disabled: boolean): { Types.Component }
	local function visit(node: Types.Component)
		if DISABLEABLE[node.type] then
			node.disabled = disabled
		end
		for _, inner in node.components or {} do
			visit(inner)
		end
		if node.accessory ~= nil then
			visit(node.accessory)
		end
	end
	for _, node in components do
		visit(node)
	end
	return components
end

return Components
