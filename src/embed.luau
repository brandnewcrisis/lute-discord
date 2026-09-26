--!strict
--[[
	Embed builder.

	Discord enforces a per-field character budget AND a 6000-character total
	across every embed in a message, and it answers a violation with a 400
	naming a JSON path (`embeds.0.fields.12.value`) rather than the limit you
	broke. Every setter here checks its own limit at the call site, where the
	stack trace still points at the code that built the value.

	Setters mutate and return `self`, so calls chain.
]]
local blame = require("@discord/blame")
local Color = require("@discord/color")
local Types = require("@discord/types")
local Util = require("@discord/util")

local LIMITS = table.freeze({
	title = 256,
	description = 4096,
	fieldName = 256,
	fieldValue = 1024,
	fields = 25,
	footer = 2048,
	author = 256,
	total = 6000,
	--- Embeds in one message.
	embeds = 10,
})

local Embed = {}
Embed.__index = Embed

export type Embed = typeof(setmetatable({} :: { data: Types.Embed }, {} :: typeof(Embed)))

local function check(name: string, text: string, limit: number)
	local length = utf8.len(text) or #text
	if length > limit then
		error(`embed {name} is {length} characters, limit is {limit}`, blame())
	end
end

function Embed.new(init: Types.Embed?): Embed
	local data: Types.Embed = init or {}
	return setmetatable({ data = data }, Embed)
end

function Embed.setTitle(self: Embed, title: string): Embed
	check("title", title, LIMITS.title)
	self.data.title = title
	return self
end

function Embed.setDescription(self: Embed, description: string): Embed
	check("description", description, LIMITS.description)
	self.data.description = description
	return self
end

function Embed.setUrl(self: Embed, url: string): Embed
	self.data.url = url
	return self
end

--[[
	Accepts a number, a `Const.Color` entry, `#rrggbb` or `#rgb`.

	Anything else is an error. This used to fall back to blurple, which
	meant a typo'd hex code shipped as the wrong colour with nothing to say
	why -- exactly the kind of silent mistake the builders exist to catch.
]]
function Embed.setColor(self: Embed, color: number | string): Embed
	local resolved = Color.resolve(color)
	if resolved == nil then
		error(`"{tostring(color)}" is not a colour: use a number, a Const.Color entry, or #rrggbb`, blame())
	end
	self.data.color = resolved
	return self
end

--- Unix seconds, or the current time when omitted.
function Embed.setTimestamp(self: Embed, unixSeconds: number?): Embed
	self.data.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(unixSeconds or os.time())) :: string
	return self
end

function Embed.setAuthor(self: Embed, name: string, iconUrl: string?, url: string?): Embed
	check("author name", name, LIMITS.author)
	self.data.author = { name = name, icon_url = iconUrl, url = url }
	return self
end

function Embed.setFooter(self: Embed, text: string, iconUrl: string?): Embed
	check("footer text", text, LIMITS.footer)
	self.data.footer = { text = text, icon_url = iconUrl }
	return self
end

function Embed.setThumbnail(self: Embed, url: string): Embed
	self.data.thumbnail = { url = url }
	return self
end

function Embed.setImage(self: Embed, url: string): Embed
	self.data.image = { url = url }
	return self
end

--[[
	Adds a field.

	An empty `value` is rejected here because Discord's own error for it is
	"This field is required", pointing at a field the caller believes they
	did set -- they set it to "".
]]
function Embed.addField(self: Embed, name: string, value: string, inline: boolean?): Embed
	check("field name", name, LIMITS.fieldName)
	check("field value", value, LIMITS.fieldValue)
	if value == "" then
		error(`embed field "{name}" has an empty value`, blame())
	end
	local fields = self.data.fields
	if fields == nil then
		fields = {}
		self.data.fields = fields
	end
	assert(fields ~= nil)
	if #fields >= LIMITS.fields then
		error(`an embed can hold {LIMITS.fields} fields`, blame())
	end
	table.insert(fields, { name = name, value = value, inline = inline })
	return self
end

--- Adds a field whose value is truncated to fit rather than throwing. For
--- values that come from users, where a long one is normal, not a bug.
function Embed.addTrimmedField(self: Embed, name: string, value: string, inline: boolean?): Embed
	return Embed.addField(self, Util.truncate(name, LIMITS.fieldName), Util.truncate(value, LIMITS.fieldValue), inline)
end

--- An invisible spacer, useful for forcing a row break between inline fields.
function Embed.addBlankField(self: Embed, inline: boolean?): Embed
	return Embed.addField(self, "\u{200b}", "\u{200b}", inline)
end

--[[
	Characters a plain embed table spends from the 6000 budget: title,
	description, footer text, author name, and every field name and value --
	the fields Discord counts. A plain-table version of `length`, so
	`@discord/payload` can total a message's embeds, builders and hand-written
	tables alike, with the same count. Non-strings (`Json.null`) count zero.
]]
function Embed.measure(data: Types.Embed): number
	local total = 0
	local function add(text: string?)
		if type(text) == "string" then
			total += utf8.len(text) or #text
		end
	end
	add(data.title)
	add(data.description)
	if data.footer then
		add(data.footer.text)
	end
	if data.author then
		add(data.author.name)
	end
	for _, field in data.fields or {} do
		add(field.name)
		add(field.value)
	end
	return total
end

--- Total characters as Discord counts them for the 6000 budget.
function Embed.length(self: Embed): number
	return Embed.measure(self.data)
end

function Embed.toJSON(self: Embed): Types.Embed
	local total = Embed.length(self)
	if total > LIMITS.total then
		error(`embed totals {total} characters, Discord's limit across all embeds in a message is {LIMITS.total}`, blame())
	end
	return self.data
end

Embed.LIMITS = LIMITS

return Embed
