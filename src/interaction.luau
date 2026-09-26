--!strict
--[[
	A wrapper around one interaction, with the response rules built in.

	Interactions have a protocol most of the ergonomics here exist to hide:

	  * The FIRST response must be sent within three seconds, or the token
	    dies and the user sees "application did not respond". Anything slower
	    must `defer` first, which buys fifteen minutes.
	  * After deferring, the reply is an EDIT of the deferred message, on a
	    different route -- so `reply` here dispatches to the right one rather
	    than making the caller remember which state they are in.
	  * A component interaction can either `update` the message it came from
	    or `reply` with a new one; both are "the first response" and only one
	    may be sent.
	  * A modal can only be the first response. It cannot follow a defer.

	Getting the state wrong produces "Interaction has already been
	acknowledged" or "Unknown interaction", neither of which says what to do,
	so the state is tracked and misuse is reported here instead.
]]
local blame = require("@discord/blame")
local Api = require("@discord/api")
local Bitfield = require("@discord/bitfield")
local Const = require("@discord/const")
local Log = require("@discord/log")
local Payload = require("@discord/payload")
local Types = require("@discord/types")
local Util = require("@discord/util")

local Interaction = {}
Interaction.__index = Interaction

--[[
	The part of the client an interaction needs, named structurally.

	`@discord/client` requires this module, so this module cannot require it
	back. All an interaction ever reaches for is the endpoint surface, so
	that is all this asks for -- and a real `Client` satisfies it.
]]
export type ClientRef = { api: Api.Api }

export type Interaction = typeof(setmetatable(
	{} :: {
		client: ClientRef,
		raw: Types.Interaction,
		id: string,
		token: string,
		applicationId: string,
		type: number,
		data: Types.InteractionData,
		guildId: string?,
		channelId: string?,
		member: Types.Member?,
		user: Types.User,
		locale: string?,
		receivedAt: Util.Instant,
		acknowledged: boolean,
		deferred: boolean,
		--- Whether the pending `defer` was ephemeral; see `reply`.
		deferredEphemeral: boolean,
	},
	{} :: typeof(Interaction)
))

function Interaction.new(client: ClientRef, raw: Types.Interaction): Interaction
	local user = raw.user or (raw.member and raw.member.user)
	return setmetatable({
		client = client,
		raw = raw,
		id = raw.id,
		token = raw.token,
		applicationId = raw.application_id,
		type = raw.type,
		data = raw.data or {},
		guildId = raw.guild_id,
		channelId = raw.channel_id,
		member = raw.member,
		user = user :: Types.User,
		locale = raw.locale,
		receivedAt = Util.now(),
		acknowledged = false,
		deferred = false,
		deferredEphemeral = false,
	}, Interaction)
end

----------------------------------------------------------------------------
-- Reading the command
----------------------------------------------------------------------------

--[[
	The invoked command as a space-separated path: `"role"`, `"role add"`,
	`"config roles add"`.

	Subcommands arrive nested inside the options array rather than in the
	name, so routing on `data.name` alone sends every subcommand of a group
	to the same handler.
]]
function Interaction.commandPath(self: Interaction): string
	local parts = { self.data.name or "" }
	local options = self.data.options
	while options ~= nil and #options > 0 do
		local first = options[1]
		if first.type ~= Const.OptionType.SUB_COMMAND and first.type ~= Const.OptionType.SUB_COMMAND_GROUP then
			break
		end
		table.insert(parts, first.name)
		options = first.options
	end
	return table.concat(parts, " ")
end

--- The option list actually holding values, i.e. the innermost subcommand's.
local function leafOptions(self: Interaction): { Types.CommandOption }
	local options: { Types.CommandOption } = self.data.options or {}
	while #options > 0 do
		local first = options[1]
		if first.type ~= Const.OptionType.SUB_COMMAND and first.type ~= Const.OptionType.SUB_COMMAND_GROUP then
			break
		end
		options = first.options or {}
	end
	return options
end

--[[
	Every supplied option as a name/value map. Absent optional options are
	simply missing, so `opts.reason or "no reason"` reads naturally.

	Values are `any`, and deliberately so. An option's type is fixed by the
	command SCHEMA, which lives in a different file from the handler and is
	not visible to Luau here, so the honest static type would be
	`string | number | boolean` -- and that turns every read into a narrowing
	dance for something the handler already knows. The typed way in is the
	`get*` family below, which resolves the id-bearing options to the objects
	Discord already sent with them.
]]
function Interaction.options(self: Interaction): { [string]: any }
	local out = {}
	for _, option in leafOptions(self) do
		out[option.name] = option.value
	end
	return out
end

--- One option by name, or `default` when it was not supplied. See
--- `options` for why the value is `any`.
function Interaction.opt(self: Interaction, name: string, default: any?): any
	for _, option in leafOptions(self) do
		if option.name == name then
			return option.value
		end
	end
	return default
end

local function resolved(self: Interaction): Types.ResolvedData
	return self.data.resolved or {}
end

--- A user option, already resolved -- no fetch needed. Discord ships the
--- full object alongside the id in `data.resolved`.
function Interaction.getUser(self: Interaction, name: string): Types.User?
	local id = Interaction.opt(self, name)
	if id == nil then
		return nil
	end
	return (resolved(self).users or {})[id]
end

function Interaction.getMember(self: Interaction, name: string): Types.Member?
	local id = Interaction.opt(self, name)
	if id == nil then
		return nil
	end
	local member = (resolved(self).members or {})[id]
	if member ~= nil and member.user == nil then
		-- Resolved members omit `user`; splice it back so callers have one
		-- object with both halves.
		member.user = (resolved(self).users or {})[id]
	end
	return member
end

function Interaction.getChannel(self: Interaction, name: string): Types.Channel?
	local id = Interaction.opt(self, name)
	if id == nil then
		return nil
	end
	return (resolved(self).channels or {})[id]
end

function Interaction.getRole(self: Interaction, name: string): Types.Role?
	local id = Interaction.opt(self, name)
	if id == nil then
		return nil
	end
	return (resolved(self).roles or {})[id]
end

function Interaction.getAttachment(self: Interaction, name: string): Types.Attachment?
	local id = Interaction.opt(self, name)
	if id == nil then
		return nil
	end
	return (resolved(self).attachments or {})[id]
end

--- The option the user is currently typing, on an autocomplete interaction.
--- Returns its name and its value so far; the value is `any` for the reason
--- given on `options`.
function Interaction.focused(self: Interaction): (string?, any)
	for _, option in leafOptions(self) do
		if option.focused then
			return option.name, option.value
		end
	end
	return nil, nil
end

--- Context-menu target: the user that was right-clicked.
function Interaction.targetUser(self: Interaction): Types.User?
	local id = self.data.target_id
	return if id ~= nil then (resolved(self).users or {})[id] else nil
end

--- Context-menu target: the message that was right-clicked.
function Interaction.targetMessage(self: Interaction): Types.Message?
	local id = self.data.target_id
	return if id ~= nil then (resolved(self).messages or {})[id] else nil
end

--[[
	The narrowing seam for required options.

	A `required = true` option is enforced by the command schema, so Discord
	never sends the command without it -- but the schema is invisible to
	Luau, which still sees `getUser` as `User?`. These say "this cannot be
	missing" once, and throw with the option's name if the schema and the
	handler ever disagree, instead of every caller writing `:: Types.User`.
]]
local function missing(name: string): string
	return `option "{name}" is required but was not supplied`
end

function Interaction.requireOpt(self: Interaction, name: string): any
	local value = Interaction.opt(self, name)
	if value == nil then
		error(missing(name), blame())
	end
	return value
end

function Interaction.requireUser(self: Interaction, name: string): Types.User
	if Interaction.opt(self, name) == nil then
		error(missing(name), blame())
	end
	local user = Interaction.getUser(self, name)
	if user == nil then
		error(`option "{name}" was supplied but Discord sent no resolved user for it`, blame())
	end
	return user
end

--- A user option who must be in this server. Distinct from a missing
--- option: a user option can name anyone, and only members resolve.
function Interaction.requireMember(self: Interaction, name: string): Types.Member
	if Interaction.opt(self, name) == nil then
		error(missing(name), blame())
	end
	local member = Interaction.getMember(self, name)
	if member == nil then
		error(`option "{name}" names a user who is not a member of this server`, blame())
	end
	return member
end

function Interaction.requireRole(self: Interaction, name: string): Types.Role
	if Interaction.opt(self, name) == nil then
		error(missing(name), blame())
	end
	local role = Interaction.getRole(self, name)
	if role == nil then
		error(`option "{name}" was supplied but Discord sent no resolved role for it`, blame())
	end
	return role
end

function Interaction.requireChannel(self: Interaction, name: string): Types.Channel
	if Interaction.opt(self, name) == nil then
		error(missing(name), blame())
	end
	local channel = Interaction.getChannel(self, name)
	if channel == nil then
		error(`option "{name}" was supplied but Discord sent no resolved channel for it`, blame())
	end
	return channel
end

function Interaction.requireAttachment(self: Interaction, name: string): Types.Attachment
	if Interaction.opt(self, name) == nil then
		error(missing(name), blame())
	end
	local attachment = Interaction.getAttachment(self, name)
	if attachment == nil then
		error(`option "{name}" was supplied but Discord sent no resolved attachment for it`, blame())
	end
	return attachment
end

--[[
	The server this came from, for handlers that only make sense in one.

	`guildId` is nil in DMs and group DMs, which a command reaches unless its
	contexts exclude them. Throwing here turns a nil deep inside the handler
	into a message that names the fix.
]]
function Interaction.requireGuildId(self: Interaction): string
	local guildId = self.guildId
	if guildId == nil then
		error("this interaction did not come from a server; mark the command guildOnly", blame())
	end
	return guildId
end

--[[
	The channel this came from.

	Discord marks `channel_id` optional without saying when. In practice it
	is on every command, component, autocomplete and modal interaction, DMs
	included, and absent only on PING -- which a gateway bot never
	receives. So this should never throw; it exists to narrow the type.
]]
function Interaction.requireChannelId(self: Interaction): string
	local channelId = self.channelId
	if channelId == nil then
		error("this interaction carries no channel id", blame())
	end
	return channelId
end

--- Values chosen in a select menu.
function Interaction.values(self: Interaction): { string }
	return self.data.values or {}
end

----------------------------------------------------------------------------
-- Reading a modal submission
----------------------------------------------------------------------------

--[[
	Every answered field in a modal submission, whatever wraps it.

	Two shapes arrive: legacy action rows holding text inputs in
	`components`, and labels holding any input in `component`. A field is
	anything with a `custom_id`; rows and labels never have one. Text
	displays come back too, with neither, and are skipped.
]]
local function submitted(self: Interaction): { Types.SubmittedComponent }
	local out: { Types.SubmittedComponent } = {}
	local function visit(node: Types.SubmittedComponent)
		if node.custom_id ~= nil then
			table.insert(out, node)
		end
		for _, inner in node.components or {} do
			visit(inner)
		end
		if node.component ~= nil then
			visit(node.component)
		end
	end
	for _, node in self.data.components or {} do
		visit(node)
	end
	return out
end

local function field(self: Interaction, id: string): Types.SubmittedComponent?
	for _, node in submitted(self) do
		if node.custom_id == id then
			return node
		end
	end
	return nil
end

--[[
	Modal fields as a `custom_id -> answer` map, from either shape.

	Text inputs and radio groups give a string (a radio group with nothing
	picked is absent), checkboxes a boolean, and selects, checkbox groups
	and file uploads an array of strings -- values, ids, or attachment ids.
	The map is `any` for the same reason `options` is: which kind a field
	is was fixed where the modal was built, out of Luau's sight. The typed
	way in is `modalValue`, `modalSelected`, `modalChecked`, `modalFiles`.
]]
function Interaction.modalValues(self: Interaction): { [string]: any }
	local out: { [string]: any } = {}
	for _, node in submitted(self) do
		local id = node.custom_id :: string
		if node.values ~= nil then
			out[id] = node.values
		elseif node.value ~= nil then
			out[id] = node.value
		end
	end
	return out
end

--- A text input's text, or a radio group's chosen value. Nil when the
--- field is absent, left empty and optional, or not a text-valued kind.
function Interaction.modalValue(self: Interaction, id: string): string?
	local node = field(self, id)
	if node ~= nil and type(node.value) == "string" then
		return node.value
	end
	return nil
end

--- What a select or checkbox group picked: option values for string
--- selects and checkbox groups, snowflakes for the auto-populated selects.
--- Always an array, empty when nothing was picked.
function Interaction.modalSelected(self: Interaction, id: string): { string }
	local node = field(self, id)
	return if node ~= nil then node.values or {} else {}
end

--- Whether a checkbox was ticked.
function Interaction.modalChecked(self: Interaction, id: string): boolean
	local node = field(self, id)
	return node ~= nil and node.value == true
end

--- The objects `ids` name in one of the `data.resolved` maps, in order,
--- skipping any Discord did not resolve.
local function pick<V>(ids: { string }, map: { [string]: V }?): { V }
	local out: { V } = {}
	if map == nil then
		return out
	end
	for _, id in ids do
		local value = map[id]
		if value ~= nil then
			table.insert(out, value)
		end
	end
	return out
end

--- The files uploaded through a file upload component, already resolved:
--- the submission carries only ids, and the objects in `data.resolved`.
function Interaction.modalFiles(self: Interaction, id: string): { Types.Attachment }
	return pick(Interaction.modalSelected(self, id), resolved(self).attachments)
end

--- Users picked in a user or mentionable select inside a modal. A
--- mentionable select's roles are skipped here; see `modalRoles`.
function Interaction.modalUsers(self: Interaction, id: string): { Types.User }
	return pick(Interaction.modalSelected(self, id), resolved(self).users)
end

function Interaction.modalRoles(self: Interaction, id: string): { Types.Role }
	return pick(Interaction.modalSelected(self, id), resolved(self).roles)
end

function Interaction.modalChannels(self: Interaction, id: string): { Types.Channel }
	return pick(Interaction.modalSelected(self, id), resolved(self).channels)
end

--- What the BOT may do in this channel, as Discord computed it. More
--- reliable than recomputing, and free -- it rides along on the payload.
function Interaction.appPermissions(self: Interaction): Bitfield.Bitfield
	return if self.raw.app_permissions ~= nil
		then Bitfield.fromString(self.raw.app_permissions)
		else Bitfield.empty
end

--- What the CALLER may do here, also precomputed by Discord.
function Interaction.memberPermissions(self: Interaction): Bitfield.Bitfield
	local member = self.member
	return if member ~= nil and member.permissions ~= nil
		then Bitfield.fromString(member.permissions)
		else Bitfield.empty
end

----------------------------------------------------------------------------
-- Responding
----------------------------------------------------------------------------

local function api(self: Interaction): Api.Api
	return self.client.api
end

local function warnIfLate(self: Interaction)
	local elapsed = Util.since(self.receivedAt)
	if elapsed > 2.5 then
		Log.warn(
			`interaction {self.id} answered after {string.format("%.1f", elapsed)}s -- `
				.. "the token may already be dead; defer() first for slow work"
		)
	end
end

--- Whether a payload asks to be seen only by the caller.
local function wantsEphemeral(payload: Types.MessageInput): boolean
	if type(payload) ~= "table" then
		return false
	end
	local flags = payload.flags
	return payload.ephemeral == true
		or (type(flags) == "number" and bit32.btest(flags, Const.MessageFlag.EPHEMERAL))
end

--[[
	Replies.

	Dispatches on state: a fresh interaction gets a real response, a deferred
	one gets its placeholder edited, and an already-answered one gets a
	follow-up. Callers can therefore write `reply` everywhere.

	Visibility is fixed by the FIRST response, and Discord ignores the
	ephemeral flag on the edit that fills in a deferred placeholder. So:

	  * An ephemeral reply after a PUBLIC `defer` is sent as an ephemeral
	    follow-up, and the public "thinking..." placeholder is deleted.
	    Editing it instead would post the "private" content for everyone.
	  * A public reply after an EPHEMERAL `defer` stays ephemeral; there is
	    no way to widen it. It edits the placeholder as usual and logs a
	    debug line, since that is rarely what was meant.

	The second return is true when the message went out as a follow-up
	rather than as (or into) the original response -- which tells a caller
	holding the message whether to edit it with `editFollowup` or
	`editReply`. The first is nil for a first response, which Discord does
	not echo back; `fetchReply` gets it.
]]
function Interaction.reply(self: Interaction, payload: Types.MessageInput): (Types.Message?, boolean)
	if self.deferred then
		local ephemeral = wantsEphemeral(payload)
		if ephemeral and not self.deferredEphemeral then
			local message = Interaction.followUp(self, payload)
			self.deferred = false
			-- The ephemeral reply is already out; a failed cleanup should
			-- not turn that into an error, only leave a stale placeholder.
			local ok, err = pcall(Interaction.deleteReply, self)
			if not ok then
				Log.warn(`interaction {self.id}: could not delete the public defer placeholder: {tostring(err)}`)
			end
			return message, true
		end
		if not ephemeral and self.deferredEphemeral then
			Log.debug(`interaction {self.id}: public reply after an ephemeral defer stays ephemeral`)
		end
		return Interaction.editReply(self, payload), false
	end
	if self.acknowledged then
		return Interaction.followUp(self, payload), true
	end
	warnIfLate(self)
	local body = Payload.message(payload)
	local files = body.files
	body.files = nil
	api(self).interactions.createResponse(
		self.id,
		self.token,
		Const.InteractionCallback.CHANNEL_MESSAGE_WITH_SOURCE,
		body,
		files
	)
	self.acknowledged = true
	return nil, false
end

--- Reply only the caller can see.
function Interaction.replyEphemeral(self: Interaction, payload: Types.MessageInput): (Types.Message?, boolean)
	local body = Payload.copy(payload)
	body.ephemeral = true
	return Interaction.reply(self, body)
end

--[[
	Buys fifteen minutes.

	Send this before anything that might take more than a second or two --
	an API call, a database read, a chain of requests. Discord shows a
	"thinking" state, and the eventual `reply` replaces it.
]]
function Interaction.defer(self: Interaction, ephemeral: boolean?)
	if self.acknowledged or self.deferred then
		return
	end
	warnIfLate(self)
	api(self).interactions.createResponse(
		self.id,
		self.token,
		Const.InteractionCallback.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE,
		{ flags = if ephemeral then Const.MessageFlag.EPHEMERAL else nil }
	)
	self.deferred = true
	self.deferredEphemeral = ephemeral == true
	self.acknowledged = true
end

--- Acknowledges a component click without changing anything on screen.
function Interaction.deferUpdate(self: Interaction)
	if self.acknowledged then
		return
	end
	api(self).interactions.createResponse(
		self.id,
		self.token,
		Const.InteractionCallback.DEFERRED_UPDATE_MESSAGE
	)
	self.acknowledged = true
end

--[[
	Edits the message a component lives on, in place.

	This is the response that makes buttons feel native: the same message
	changes rather than a new one appearing. Only valid for component and
	modal interactions -- there is no message to update on a slash command.

	An edit in every sense, so the payload is checked as one: it may name
	only the fields that change, and need not resend a V2 message's layout.
]]
function Interaction.update(self: Interaction, payload: Types.MessageInput)
	if self.acknowledged then
		Interaction.editReply(self, payload)
		return
	end
	local body = Payload.message(payload, { edit = true })
	local files = body.files
	body.files = nil
	api(self).interactions.createResponse(
		self.id,
		self.token,
		Const.InteractionCallback.UPDATE_MESSAGE,
		body,
		files
	)
	self.acknowledged = true
end

function Interaction.editReply(self: Interaction, payload: Types.MessageInput): Types.Message
	local message = api(self).interactions.editOriginalResponse(self.applicationId, self.token, payload)
	self.deferred = false
	self.deferredEphemeral = false
	self.acknowledged = true
	return message
end

function Interaction.followUp(self: Interaction, payload: Types.MessageInput): Types.Message
	return api(self).interactions.createFollowup(self.applicationId, self.token, payload)
end

function Interaction.deleteReply(self: Interaction)
	api(self).interactions.deleteOriginalResponse(self.applicationId, self.token)
end

function Interaction.fetchReply(self: Interaction): Types.Message
	return api(self).interactions.getOriginalResponse(self.applicationId, self.token)
end

--- Opens a modal. Must be the first response -- see the module comment.
function Interaction.showModal(self: Interaction, modal: Types.Buildable<Types.Modal>)
	if self.acknowledged then
		error("a modal must be the first response to an interaction; this one was already acknowledged", blame())
	end
	api(self).interactions.createResponse(self.id, self.token, Const.InteractionCallback.MODAL, Payload.toJSON(modal))
	self.acknowledged = true
end

--[[
	Answers an autocomplete interaction.

	Up to 25 choices, and the response must be fast -- Discord gives
	autocomplete the same three seconds, but the user is typing, so anything
	over a couple hundred milliseconds feels broken. This is not a normal
	reply and does not count as acknowledging the command itself.
]]
function Interaction.autocomplete(self: Interaction, choices: { Types.AutocompleteChoice })
	local trimmed = choices
	if #choices > 25 then
		trimmed = table.move(choices, 1, 25, 1, {})
	end
	api(self).interactions.createResponse(
		self.id,
		self.token,
		Const.InteractionCallback.APPLICATION_COMMAND_AUTOCOMPLETE_RESULT,
		{ choices = trimmed }
	)
	self.acknowledged = true
end

return Interaction
