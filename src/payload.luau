--!strict
--[[
	Normalises what a caller passes into what Discord accepts.

	Four conveniences the API itself does not offer:

	  * `ephemeral = true` becomes the flag bit. Everyone reaches for the word
	    first, and the bit (64) is unmemorable.
	  * Builders (embeds, components, modals) are unwrapped by calling
	    `toJSON`, so a builder and a plain table are interchangeable anywhere.
	  * `content = ""` with nothing else is rejected here rather than by
	    Discord, because its error for that ("Cannot send an empty message")
	    arrives without saying which of your four fields was the empty one.
	    Creates only: an edit names just the fields it changes, so
	    `Payload.message(input, { edit = true })` skips the rule.
	  * Components V2: the flag is set for you, and the fields a V2 message
	    may not carry are refused here -- Discord answers both mistakes
	    with a bare 400. See `applyV2`.
]]
local blame = require("@discord/blame")
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Json = require("@discord/json")
local Types = require("@discord/types")

local Payload = {}

--[[
	Unwraps a builder, recursing into arrays of them.

	`any` in and `any` out is deliberate and is the one signature here that
	cannot be tightened: this is the seam where a builder object becomes the
	plain table it stands for, and Luau has no way to say "the same shape,
	one wrapper removed". Callers know which of the two they passed; the
	function does not need to.
]]
function Payload.toJSON(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local node = value :: { [any]: any }
	local build = node.toJSON
	if type(build) == "function" then
		return (build :: (any) -> any)(node)
	end
	if #node > 0 then
		local out = table.create(#node)
		for index, item in ipairs(node) do
			out[index] = Payload.toJSON(item)
		end
		return out
	end
	return node
end

--[[
	A shallow copy of a payload, still a payload.

	Callers that need to add a field before sending -- the reply reference in
	`Client.reply`, the ephemeral flag in `Interaction.replyEphemeral` -- must
	not write it onto the table they were handed, which belongs to the caller
	and may be a reused constant.
]]
function Payload.copy(input: Types.MessageInput): Types.MessagePayload
	local out: Types.MessagePayload = {}
	if type(input) == "string" then
		out.content = input
		return out
	end
	for key, value in input do
		out[key] = value
	end
	return out
end

--- Every `attachment://` name a component tree points at.
local function attachmentRefs(components: { Types.Component }): { string }
	local out: { string } = {}
	local function take(url: string?)
		local filename = if url ~= nil then string.match(url, "^attachment://(.+)$") else nil
		if filename ~= nil then
			table.insert(out, filename)
		end
	end
	local function visit(node: Types.Component)
		if node.media ~= nil then
			take(node.media.url)
		end
		if node.file ~= nil then
			take(node.file.url)
		end
		for _, item in node.items or {} do
			take(item.media.url)
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
	return out
end

--[[
	The `attachment://` names a message can point at, or nil when that is
	unknowable here.

	Built from the uploads' `files[].name` plus the `filename` of every entry
	in the caller's `attachments`: an entry there either describes an upload
	(possibly renaming it) or, on an edit, keeps a file the message already
	has, and both are valid targets.

	On an edit the set is only complete when the caller sent `attachments`
	and every entry names its file. Without the array, Discord keeps every
	existing attachment; with an id-only entry, a kept file's name is on
	Discord's side, not in this payload. Either way a reference this cannot
	match may still be valid, so the check is skipped rather than guessed.
	On a create there are no existing attachments, but the check still runs
	only when the payload uploads or lists something, as before.
]]
local function attachmentNames(out: Types.MessageBody, edit: boolean): { [string]: boolean }?
	local names: { [string]: boolean } = {}
	local any = false
	local files = out.files
	if type(files) == "table" then
		for _, file in files :: { Types.File } do
			names[file.name] = true
			any = true
		end
	end
	local attachments = out.attachments
	if type(attachments) == "table" then
		for _, entry in attachments :: { Types.PartialAttachment } do
			if type(entry.filename) == "string" then
				names[entry.filename] = true
				any = true
			elseif edit then
				return nil
			end
		end
	elseif edit then
		return nil
	end
	if not edit and not any then
		return nil
	end
	return names
end

--[[
	Components V2: sets the flag and refuses what a V2 message cannot carry.
	Returns whether the message is V2.

	The flag is set when the caller says `v2 = true`, and also when the
	components include a V2-only kind (text, section, container and the
	rest). Detection only ever fires where the request would otherwise be
	certain to fail -- Discord refuses those kinds without the flag -- so it
	cannot change the meaning of a valid legacy message. A list of action
	rows alone is valid either way and stays legacy unless asked: the flag
	is permanent on a message and switches off `content` and `embeds` for
	every later edit, so it is not something to infer from ambiguous input.
	`v2 = false` is an explicit "never", turning V2 kinds into an error
	instead of an upgrade.

	A `components` that is not a table is "no components" throughout: on an
	edit, `Json.null` means "remove them all" and goes to Discord untouched.
]]
local function applyV2(out: Types.MessageBody, requested: boolean?, edit: boolean): boolean
	local components: { Types.Component } = if type(out.components) == "table" then out.components else {}
	local needed = Components.isV2(components)
	if requested == false and needed then
		error("v2 = false, but the components include Components V2 kinds (text, section, container, ...)", blame())
	end
	if requested == true or needed then
		out.flags = bit32.bor(out.flags or 0, Const.MessageFlag.IS_COMPONENTS_V2)
	end
	local v2 = bit32.btest(out.flags or 0, Const.MessageFlag.IS_COMPONENTS_V2)
	if v2 then
		-- `Json.null` and `{}` are how an edit that converts a legacy message
		-- CLEARS these fields, which Discord requires; only a real value is
		-- a conflict.
		if type(out.content) == "string" and out.content ~= "" then
			error("a Components V2 message cannot carry content; put the text in Components.text", blame())
		end
		if type(out.embeds) == "table" and #out.embeds > 0 then
			error("a Components V2 message cannot carry embeds; Components.container is the replacement", blame())
		end
		if out.poll ~= nil and out.poll ~= Json.null then
			error("a Components V2 message cannot carry a poll", blame())
		end
		if type(out.sticker_ids) == "table" and #out.sticker_ids > 0 then
			error("a Components V2 message cannot carry stickers", blame())
		end
		--[[
			A V2 message shows only its components, so a create needs at
			least one. An edit that leaves `components` out keeps the ones
			the message has -- a flags-only or attachments-only edit is
			normal -- so on an edit only an explicit clear (`{}` or
			`Json.null`) of a message this payload marks V2 is certain to
			fail.
		]]
		if #components == 0 and (not edit or out.components ~= nil) then
			error("a Components V2 message shows only its components; give it at least one", blame())
		end
		--[[
			Uploads are invisible in a V2 message unless a component points
			at them, and a pointer to a file the message does not have fails
			with a generic error. See `attachmentNames` for when the set of
			names is known well enough to check.
		]]
		local names = attachmentNames(out, edit)
		if names ~= nil then
			for _, filename in attachmentRefs(components) do
				if not names[filename] then
					error(
						`a component points at attachment://{filename}, but no file of that name is in files or attachments`
					, blame())
				end
			end
		end
	end
	if #components > 0 then
		--[[
			Which limits apply depends on the TARGET message's flag. A create
			knows it. An edit without the flag in hand does not: the message
			being edited may already be V2, where six action rows are fine,
			and resending the flag is not required. So an edit that has not
			said `v2 = false` is checked against the V2 rules -- the looser
			ceiling, 40 components rather than 5 rows -- without setting the
			flag. A legacy target that breaks the 5-row rule is then left for
			Discord to refuse, the price of not refusing valid V2 edits.
		]]
		local lenient = edit and not v2 and requested ~= false
		Components.validate(components, v2 or lenient)
	end
	return v2
end

--[[
	What a message is being sent as.

	`edit = true` for a PATCH of an existing message (the edit routes, an
	interaction's `update`, and a reply after `defer`, which edits the
	placeholder). Discord documents every edit field as optional and
	nullable, so the emptiness rule is off, a V2 edit need not resend its
	components, and component limits allow for a target that is already V2.
]]
export type MessageOptions = {
	edit: boolean?,
}

--- Whether a create carries anything Discord will show. Each field counts
--- only with a real value: `{}` and `Json.null` are clears, not content.
local function hasBody(out: Types.MessageBody): boolean
	local function filled(value: any): boolean
		return type(value) == "table" and #value > 0
	end
	local reference = out.message_reference
	-- A forward (reference type 1) is the whole message; a plain reply
	-- (type 0, the default) still needs something of its own.
	local forward = type(reference) == "table" and reference.type == 1
	return (type(out.content) == "string" and out.content ~= "")
		or filled(out.embeds)
		or filled(out.components)
		or filled(out.files)
		or filled(out.sticker_ids)
		or filled(out.attachments)
		or (out.poll ~= nil and out.poll ~= Json.null)
		or forward
end

--[[
	Turns a `MessagePayload` into the exact body Discord expects. A bare
	string is accepted as shorthand for `{ content = ... }`.

	`options.edit` marks a PATCH of an existing message; see `MessageOptions`.
]]
function Payload.message(input: Types.MessageInput, options: MessageOptions?): Types.MessageBody
	if type(input) == "string" then
		return { content = input }
	end
	local edit = options ~= nil and options.edit == true
	local out: Types.MessageBody = {}
	for key, value in input do
		out[key] = value
	end
	local v2Requested: boolean? = out.v2
	out.v2 = nil

	if out.ephemeral ~= nil then
		if out.ephemeral == true then
			out.flags = bit32.bor(out.flags or 0, Const.MessageFlag.EPHEMERAL)
		end
		out.ephemeral = nil
	end
	if out.silent ~= nil then
		if out.silent == true then
			out.flags = bit32.bor(out.flags or 0, Const.MessageFlag.SUPPRESS_NOTIFICATIONS)
		end
		out.silent = nil
	end
	if out.embeds ~= nil then
		out.embeds = Payload.toJSON(out.embeds)
	end
	if out.embed ~= nil then
		-- Singular is the shape people type by accident; accept it.
		out.embeds = { Payload.toJSON(out.embed) }
		out.embed = nil
	end
	--[[
		The message-wide embed limits. `Embed.toJSON` checks one embed's
		6000 characters, but the budget is shared by every embed in the
		message, and so is the cap of ten; Discord reports either as an
		unexplained 400 on `embeds`.
	]]
	local embeds = out.embeds
	if type(embeds) == "table" then
		local list = embeds :: { Types.Embed }
		if #list > Embed.LIMITS.embeds then
			error(`a message holds at most {Embed.LIMITS.embeds} embeds, got {#list}`, blame())
		end
		local total = 0
		for _, embed in list do
			total += Embed.measure(embed)
		end
		if total > Embed.LIMITS.total then
			error(`embeds total {total} characters, Discord's limit across all embeds in a message is {Embed.LIMITS.total}`, blame())
		end
	end
	if out.components ~= nil then
		out.components = Payload.toJSON(out.components)
	end
	if out.poll ~= nil then
		out.poll = Payload.toJSON(out.poll)
	end
	--[[
		`allowedMentions` -> `allowed_mentions`.

		Worth special-casing rather than leaving to the caller: an unknown
		key is copied through untouched, so the camelCase spelling reaches
		Discord as a field it does not recognise, is ignored, and the message
		pings everyone it mentions after all. The failure is silent and it is
		the expensive direction to get wrong.
	]]
	if out.allowedMentions ~= nil then
		out.allowed_mentions = out.allowedMentions
		out.allowedMentions = nil
	end

	if applyV2(out, v2Requested, edit) then
		-- `applyV2` has already insisted on components where a V2 message
		-- needs them, so the general emptiness rule below has nothing to add.
		return out
	end

	--[[
		Only a create can be empty. An edit changes just the fields it
		names -- `{ components = {} }` strips the buttons, `{ flags = 4 }`
		hides the embeds -- so every field being absent or cleared is normal.
	]]
	if not edit and not hasBody(out) then
		error("message payload is empty: set at least one of content, embeds, components, files or poll", blame())
	end
	return out
end

--- Suppresses every ping -- users, roles, @everyone and @here -- while still
--- letting the message *contain* the mentions, which render but notify no
--- one. Anything echoing user input should pass this.
Payload.NO_MENTIONS = table.freeze({ parse = {} }) :: Types.AllowedMentions

--[[
	Builds an `allowed_mentions` object.

	Two forms, and they do not mix -- Discord rejects a payload that both
	parses a category and lists ids from it. Pass booleans to allow a whole
	category, or `userIds` / `roleIds` to allow exactly those and nothing
	else, which is what anything echoing user input wants: a message can then
	name a role without being able to ping it.
]]
function Payload.allowedMentions(options: {
	users: boolean?,
	roles: boolean?,
	everyone: boolean?,
	userIds: { string }?,
	roleIds: { string }?,
}): Types.AllowedMentions
	local parse = {}
	-- A category listed in `parse` cannot also be given explicit ids, so the
	-- id list wins where both are set.
	if options.users and options.userIds == nil then
		table.insert(parse, "users")
	end
	if options.roles and options.roleIds == nil then
		table.insert(parse, "roles")
	end
	if options.everyone then
		table.insert(parse, "everyone")
	end
	return {
		parse = parse,
		users = options.userIds,
		roles = options.roleIds,
	}
end

return Payload
