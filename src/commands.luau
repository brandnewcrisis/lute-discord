--!strict
--[[
	Slash command and context-menu builders.

	The point of a builder here, rather than hand-written tables, is that the
	command SCHEMA is the one part of a bot Discord validates strictly and
	only at deploy time: names must be lowercase and match a specific
	character class, descriptions are mandatory on chat-input commands but
	forbidden on context-menu ones, required options must precede optional
	ones, and a command may nest subcommands one level but not two. Every one
	of those is checked here, at the call that got it wrong: errors are
	raised at the first frame outside the library (see `@discord/blame`),
	so the message points at the line in the bot, not in this file.

	The shape mirrors Discord's: a command holds options; an option of type
	SUB_COMMAND holds its own options; a SUB_COMMAND_GROUP holds subcommands.

	A command can also carry its handler, which keeps the schema and the code
	that answers it in one place -- the usual way a bot breaks is a renamed
	option or command that the handler, in another file, never heard about:

		local ping = Commands.slash("ping", "Check I am alive"):handle(function(ix)
			ix:reply("pong")
		end)
		client:register({ ping })
		client:deploy()
]]
local blame = require("@discord/blame")
local Const = require("@discord/const")
local Interaction = require("@discord/interaction")
local Spec = require("@discord/spec")
local Types = require("@discord/types")

local Commands = {}

-- Discord's rule is `^[-_'\p{L}\p{N}]{1,32}$`, lowercase where a letter has
-- a lowercase form. Luau patterns know only ASCII classes, so non-ASCII
-- bytes are let through (Discord checks those) and ASCII capitals are not.
local NAME_PATTERN = "^[%l%d_%-'\128-\255]+$"

local OPTION_TYPES: { [string]: number } = {
	string = Const.OptionType.STRING,
	integer = Const.OptionType.INTEGER,
	number = Const.OptionType.NUMBER,
	boolean = Const.OptionType.BOOLEAN,
	user = Const.OptionType.USER,
	channel = Const.OptionType.CHANNEL,
	role = Const.OptionType.ROLE,
	mentionable = Const.OptionType.MENTIONABLE,
	attachment = Const.OptionType.ATTACHMENT,
}

local function chars(text: string): number
	return utf8.len(text) or #text
end

local function checkName(name: string, what: string)
	local length = chars(name)
	if length < 1 or length > 32 then
		error(`{what} name "{name}" must be 1 to 32 characters`, blame())
	end
	-- Discord's rule, and it rejects the whole deploy over one bad name.
	if string.match(name, NAME_PATTERN) == nil then
		error(`{what} name "{name}" must be lowercase letters, digits, -, _ and ' only`, blame())
	end
end

local function checkDescription(description: string, what: string)
	local length = chars(description)
	if length < 1 or length > 100 then
		error(`{what} description must be 1 to 100 characters (got {length})`, blame())
	end
end

export type Choice = Types.ApplicationCommandChoice

export type OptionSpec = {
	name: string,
	description: string,
	type: string,
	required: boolean?,
	choices: { Choice }?,
	--- Ask Discord to send AUTOCOMPLETE interactions as the user types.
	--- Mutually exclusive with `choices`.
	autocomplete: boolean?,
	min: number?,
	max: number?,
	minLength: number?,
	maxLength: number?,
	--- Channel options only: which channel types to offer.
	channelTypes: { number }?,
	--- Per-locale names and descriptions, keyed like `"de"` or `"pt-BR"`.
	nameLocalizations: { [string]: string }?,
	descriptionLocalizations: { [string]: string }?,
}

local OPTION_SPEC_KEYS = Spec.keys({
	"name",
	"description",
	"type",
	"required",
	"choices",
	"autocomplete",
	"min",
	"max",
	"minLength",
	"maxLength",
	"channelTypes",
	"nameLocalizations",
	"descriptionLocalizations",
})

local OPTION_EXTRA_KEYS = Spec.keys({
	"required",
	"choices",
	"autocomplete",
	"min",
	"max",
	"minLength",
	"maxLength",
	"channelTypes",
	"nameLocalizations",
	"descriptionLocalizations",
})

-- Discord's wire names, which are what people type when copying from the
-- API docs, mapped to this builder's.
local OPTION_ALIASES = {
	min_value = "min",
	max_value = "max",
	minValue = "min",
	maxValue = "max",
	min_length = "minLength",
	max_length = "maxLength",
	channel_types = "channelTypes",
	name_localizations = "nameLocalizations",
	description_localizations = "descriptionLocalizations",
}

--- Everything a shorthand option helper accepts, i.e. an `OptionSpec` with
--- the three arguments it already takes positionally removed.
export type OptionExtra = {
	required: boolean?,
	choices: { Choice }?,
	autocomplete: boolean?,
	min: number?,
	max: number?,
	minLength: number?,
	maxLength: number?,
	channelTypes: { number }?,
	nameLocalizations: { [string]: string }?,
	descriptionLocalizations: { [string]: string }?,
}

-- Which option types each constraint applies to. Discord ignores or rejects
-- a constraint on the wrong type, and the likeliest mistake -- `min` on a
-- string, meaning its length -- is silently ignored, so it is caught here.
local NUMERIC = { integer = true, number = true }
local CHOOSABLE = { string = true, integer = true, number = true }

local function buildOption(spec: OptionSpec): Types.ApplicationCommandOption
	Spec.check(spec, OPTION_SPEC_KEYS, `option "{spec.name}"`, OPTION_ALIASES)
	checkName(spec.name, "option")
	checkDescription(spec.description, "option")
	local kind = OPTION_TYPES[spec.type]
	if kind == nil then
		error(`unknown option type "{spec.type}"`, blame())
	end
	local label = `option "{spec.name}"`
	if spec.choices ~= nil and spec.autocomplete then
		error(`{label} cannot have both choices and autocomplete`, blame())
	end
	if spec.choices ~= nil and #spec.choices > 25 then
		error(`{label} has {#spec.choices} choices, limit is 25`, blame())
	end
	if (spec.choices ~= nil or spec.autocomplete) and not CHOOSABLE[spec.type] then
		error(`{label}: choices and autocomplete apply to string, integer and number options only`, blame())
	end
	if (spec.min ~= nil or spec.max ~= nil) and not NUMERIC[spec.type] then
		local hint = if spec.type == "string" then "; for a string's length use minLength/maxLength" else ""
		error(`{label}: min/max apply to integer and number options{hint}`, blame())
	end
	if (spec.minLength ~= nil or spec.maxLength ~= nil) and spec.type ~= "string" then
		error(`{label}: minLength/maxLength apply to string options only`, blame())
	end
	if spec.channelTypes ~= nil and spec.type ~= "channel" then
		error(`{label}: channelTypes applies to channel options only`, blame())
	end
	return {
		type = kind,
		name = spec.name,
		description = spec.description,
		required = spec.required,
		choices = spec.choices,
		autocomplete = spec.autocomplete,
		min_value = spec.min,
		max_value = spec.max,
		min_length = spec.minLength,
		max_length = spec.maxLength,
		channel_types = spec.channelTypes,
		name_localizations = spec.nameLocalizations,
		description_localizations = spec.descriptionLocalizations,
	}
end

local Command = {}
Command.__index = Command

--[[
	A command under construction.

	`data` is the payload Discord will receive. The same builder also backs
	subcommands, whose payload is an OPTION rather than a command -- see
	`subcommand` for where the two meet.
]]
--- What `handle` and `onAutocomplete` accept. The return is ignored; it is
--- `...any` so a handler can end with `return ix:reply(...)`.
export type Handler = (Interaction.Interaction) -> ...any

export type Command = typeof(setmetatable(
	{} :: {
		data: Types.ApplicationCommand,
		_run: Handler?,
		_autocomplete: Handler?,
		--- Subcommand and group builders, kept so their handlers can be
		--- found; their payloads already live in `data.options`.
		_children: { any },
		--- Set on a subcommand group's builder. `data.type` cannot say so:
		--- a group's option type (2) is also a user context menu's command type.
		_group: boolean?,
	},
	{} :: typeof(Command)
))

local function new(data: Types.ApplicationCommand): Command
	return setmetatable({
		data = data,
		_run = nil :: Handler?,
		_autocomplete = nil :: Handler?,
		_children = {},
		_group = nil :: boolean?,
	}, Command)
end

--[[
	Appends an option, enforcing the ordering rule.

	Discord requires every required option to come before every optional one
	-- otherwise the argument the user types second could belong to either.
	It rejects the whole command if you get it wrong, so it is caught here.
]]
local function isNesting(option: Types.ApplicationCommandOption): boolean
	return option.type == Const.OptionType.SUB_COMMAND or option.type == Const.OptionType.SUB_COMMAND_GROUP
end

local function addOption(data: Types.ApplicationCommand, option: Types.ApplicationCommandOption)
	local options = data.options or {}
	data.options = options
	for _, existing in options do
		-- A level holds subcommands (or groups) OR plain options, never both:
		-- once a command branches, its arguments belong to the branches.
		if isNesting(existing) ~= isNesting(option) then
			error(`"{option.name}": a command cannot mix subcommands or groups with plain options at the same level`, blame())
		end
		if option.required and not existing.required and not isNesting(existing) then
			error(`required option "{option.name}" must come before optional option "{existing.name}"`, blame())
		end
		if existing.name == option.name then
			error(`two options are both named "{option.name}"`, blame())
		end
	end
	if #options >= 25 then
		error("a command takes at most 25 options", blame())
	end
	table.insert(options, option)
end

local function option(self: Command, spec: OptionSpec): Command
	addOption(self.data, buildOption(spec))
	return self
end

function Command.option(self: Command, spec: OptionSpec): Command
	return option(self, spec)
end

--[[
	Shorthand for the common option types.

	`extra` is copied into a fresh spec rather than written through, so a
	table of shared defaults can be passed to several options without the
	first call stamping its name onto it.
]]
local function shorthand(self: Command, name: string, description: string, kind: string, extra: OptionExtra?): Command
	local more: OptionExtra = extra or {}
	-- Checked here, before the known fields are copied out: a misspelled
	-- key would otherwise be dropped without a trace.
	Spec.check(more, OPTION_EXTRA_KEYS, `option "{name}"`, OPTION_ALIASES)
	-- Level 3: this frame, the public shorthand that called it, then the bot.
	return option(self, {
		name = name,
		description = description,
		type = kind,
		required = more.required,
		choices = more.choices,
		autocomplete = more.autocomplete,
		min = more.min,
		max = more.max,
		minLength = more.minLength,
		maxLength = more.maxLength,
		channelTypes = more.channelTypes,
		nameLocalizations = more.nameLocalizations,
		descriptionLocalizations = more.descriptionLocalizations,
	})
end

function Command.stringOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "string", extra)
end

function Command.integerOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "integer", extra)
end

--- A decimal number. Use `integerOption` when fractions make no sense.
function Command.numberOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "number", extra)
end

--- A user OR a role. Arrives as an id; look it up in `ix.data.resolved`.
function Command.mentionableOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "mentionable", extra)
end

function Command.userOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "user", extra)
end

function Command.channelOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "channel", extra)
end

function Command.roleOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "role", extra)
end

function Command.booleanOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "boolean", extra)
end

function Command.attachmentOption(self: Command, name: string, description: string, extra: OptionExtra?): Command
	return shorthand(self, name, description, "attachment", extra)
end

--[[
	A subcommand. `build` receives a nested Command to add options to.

	Nesting is one level deep: a command holds subcommands, or a command holds
	groups which hold subcommands, but a group cannot hold another group. That
	is Discord's limit, not this library's.
]]
function Command.subcommand(self: Command, name: string, description: string, build: ((Command) -> ())?): Command
	checkName(name, "subcommand")
	checkDescription(description, "subcommand")
	local childData: Types.ApplicationCommand =
		{ type = Const.OptionType.SUB_COMMAND, name = name, description = description }
	local child = new(childData)
	if build then
		build(child)
	end
	table.insert(self._children, child)
	-- Discord models a subcommand as an option that holds options, so the
	-- payload a nested `Command` accumulates IS an option once it is done.
	-- The two shapes differ only in which fields are mandatory, which is why
	-- this is the one place the builder has to say so.
	addOption(self.data, (childData :: any) :: Types.ApplicationCommandOption)
	return self
end

function Command.group(self: Command, name: string, description: string, build: (Command) -> ()): Command
	checkName(name, "group")
	checkDescription(description, "group")
	local childData: Types.ApplicationCommand =
		{ type = Const.OptionType.SUB_COMMAND_GROUP, name = name, description = description }
	local child = new(childData)
	child._group = true
	build(child)
	table.insert(self._children, child)
	for _, option in childData.options or {} do
		if option.type == Const.OptionType.SUB_COMMAND_GROUP then
			error(`group "{name}" cannot contain another group`, blame())
		end
	end
	addOption(self.data, (childData :: any) :: Types.ApplicationCommandOption)
	return self
end

--[[
	The permissions a member needs for the command to appear at all.

	This is a DEFAULT: server admins can override it per role in Server
	Settings, so it is a usability feature, not a security boundary. Commands
	that must not run without a permission still have to check at invoke time.
]]
function Command.defaultPermissions(self: Command, ...: string): Command
	local Permissions = require("@discord/permissions")
	local ok, bits = pcall(Permissions.of, ...)
	if not ok then
		-- Re-raised here so an unknown name is reported at the bot's line.
		local message = string.gsub(tostring(bits), "^[^:]*:%d+: ", "")
		error(message, blame())
	end
	self.data.default_member_permissions = bits:toString()
	return self
end

--[[
	Hides the command in DMs. Guild-only commands should set this, or they
	appear in DMs and fail with a confusing error.

	`guildOnly(false)` allows servers and the bot's DMs. Group DMs and other
	people's DMs (context 2) exist only for user-installed apps; see
	`userInstallable`.
]]
function Command.guildOnly(self: Command, value: boolean?): Command
	self.data.contexts = if value == false then { 0, 1 } else { 0 }
	return self
end

--[[
	Makes the command available when a USER installs the app to their
	account, not only when a server does -- so it works in any server, DM or
	group DM the user is in, even ones the bot has not joined.

	The app must also have User Install enabled under Installation in the
	developer portal. In those places the bot is not a member, so the
	interaction carries no guild object, the cache knows nothing, and only
	the interaction token can answer; reply rather than calling channel
	routes.
]]
function Command.userInstallable(self: Command): Command
	self.data.integration_types = { 0, 1 }
	self.data.contexts = { 0, 1, 2 }
	return self
end

--- Marks the command as handling sensitive content (18+ gated).
function Command.nsfw(self: Command, value: boolean?): Command
	self.data.nsfw = value ~= false
	return self
end

function Command.localize(self: Command, names: { [string]: string }?, descriptions: { [string]: string }?): Command
	self.data.name_localizations = names
	self.data.description_localizations = descriptions
	return self
end

--[[
	Sets the function that answers this command -- or, called on the builder
	a `subcommand` callback receives, that subcommand. `client:register`
	collects them all by their full path ("role add").

	A command that has subcommands is answered by them; giving it a handler
	of its own as well is allowed and acts as the fallback for any
	subcommand without one.
]]
function Command.handle(self: Command, fn: Handler): Command
	-- Discord never invokes a group itself -- only the subcommands inside
	-- it -- so a handler here could never run.
	if self._group then
		error(`group "{self.data.name}" cannot have a handler; put one on each of its subcommands`, blame())
	end
	self._run = fn
	return self
end

--- Sets the autocomplete handler for this command or subcommand. It is
--- called for every option marked `autocomplete = true`; `ix:focused()`
--- says which one the user is typing in.
function Command.onAutocomplete(self: Command, fn: Handler): Command
	if self._group then
		error(`group "{self.data.name}" cannot have an autocomplete handler; put one on its subcommands`, blame())
	end
	self._autocomplete = fn
	return self
end

function Command.toJSON(self: Command): Types.ApplicationCommand
	return self.data
end

--- A `/name` command.
function Commands.slash(name: string, description: string): Command
	checkName(name, "command")
	checkDescription(description, "command")
	local data: Types.ApplicationCommand = { type = Const.CommandType.CHAT_INPUT, name = name, description = description }
	return new(data)
end

--[[
	A right-click entry on a user or a message.

	Context-menu commands must NOT carry a description -- Discord rejects one
	that does -- and their names are displayed verbatim, so they are the only
	command names allowed capitals and spaces.
]]
function Commands.userCommand(name: string): Command
	if chars(name) < 1 or chars(name) > 32 then
		error(`context menu name "{name}" must be 1 to 32 characters`, blame())
	end
	local data: Types.ApplicationCommand = { type = Const.CommandType.USER, name = name }
	return new(data)
end

function Commands.messageCommand(name: string): Command
	if chars(name) < 1 or chars(name) > 32 then
		error(`context menu name "{name}" must be 1 to 32 characters`, blame())
	end
	local data: Types.ApplicationCommand = { type = Const.CommandType.MESSAGE, name = name }
	return new(data)
end

export type HandlerEntry = {
	--- "ping", "role add", "config roles add", or a context menu's name.
	path: string,
	--- `Const.CommandType` of the top-level command.
	type: number,
	run: Handler?,
	autocomplete: Handler?,
}

--[[
	Every handler attached to `command` and its subcommands, with the path
	each answers to. What `client:register` walks; exposed so a bot with its
	own router can do the same.
]]
function Commands.handlers(command: Command): { HandlerEntry }
	local out: { HandlerEntry } = {}
	local kind = command.data.type or Const.CommandType.CHAT_INPUT
	local function walk(node: Command, path: string)
		if node._run ~= nil or node._autocomplete ~= nil then
			table.insert(out, { path = path, type = kind, run = node._run, autocomplete = node._autocomplete })
		end
		for _, child in node._children do
			local childCommand = child :: Command
			walk(childCommand, `{path} {childCommand.data.name}`)
		end
	end
	walk(command, command.data.name)
	return out
end

Commands.Command = Command

return Commands
